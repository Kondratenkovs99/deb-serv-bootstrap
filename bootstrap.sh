#!/usr/bin/env bash
# deb-serv-bootstrap: reusable Debian 13 provisioning.
set -Eeuo pipefail
umask 027
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

root_ssh=false
reboot_after=false
usage() {
    cat <<'EOF'
Usage: sudo bash bootstrap.sh [--enable-root-password-ssh] [--reboot]
  --enable-root-password-ssh  Explicitly allow root SSH password authentication.
  --reboot                    Reboot only after all required checks pass.
  --help                      Show this help without changing the system.
EOF
}
for option in "$@"; do
    case "$option" in
        --enable-root-password-ssh) root_ssh=true ;;
        --reboot) reboot_after=true ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root or with sudo.'
[[ -r /etc/os-release ]] || die 'Missing operating system metadata.'
source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || die 'Debian 13 is required.'
[[ -d /run/systemd/system ]] || die 'A running systemd system is required.'
exec 9>/run/lock/deb-serv-bootstrap.lock
flock -n 9 || die 'Another bootstrap run is active.'

install -d -m 0700 /var/log/deb-serv-bootstrap
log_file=$(mktemp /var/log/deb-serv-bootstrap/run-XXXXXXXX.log)
chmod 0600 "$log_file"
exec > >(tee -a "$log_file") 2>&1
printf 'Bootstrap started: %s\nLog: %s\n' "$(date -u +%FT%TZ)" "$log_file"
ssh_pending=false
ssh_backup=''
temp_dir=$(mktemp -d)
cleanup() { rm -rf -- "$temp_dir"; }
rollback_ssh() {
    if $ssh_pending; then
        printf 'Restoring SSH configuration from %s\n' "$ssh_backup"
        cp -a -- "$ssh_backup" /etc/ssh/sshd_config
        /usr/sbin/sshd -t && systemctl reload ssh.service
        ssh_pending=false
    fi
}
on_error() {
    local status=$?
    trap - ERR
    set +e
    rollback_ssh
    printf 'Bootstrap failed (exit %s). Review %s before retrying.\n' "$status" "$log_file"
    exit "$status"
}
trap cleanup EXIT
trap on_error ERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'status=$?; if $ssh_pending; then rollback_ssh; fi; cleanup; exit "$status"' EXIT

# Refuse conflicting engines instead of removing packages or workloads.
for package in docker.io docker-compose docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
        die "Conflicting package installed: $package. Resolve it before running."
    fi
done
# Existing third-party source definitions need manual reconciliation.
if grep -RslE 'download[.]docker[.]com' /etc/apt/sources.list /etc/apt/sources.list.d \
    2>/dev/null | grep -vFx /etc/apt/sources.list.d/deb-serv-bootstrap-docker.sources; then
    die 'An existing Docker repository definition requires manual reconciliation.'
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get install -y ca-certificates curl gnupg sudo git vim-tiny htop tmux \
    jq unzip rsync lsof dnsutils iproute2 procps openssh-server

# Use Docker's signed, official Debian repository and Compose plugin.
install -d -m 0755 /etc/apt/keyrings
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    https://download.docker.com/linux/debian/gpg -o "$temp_dir/docker.asc"
gpg --batch --show-keys "$temp_dir/docker.asc" >/dev/null
install -m 0644 "$temp_dir/docker.asc" /etc/apt/keyrings/deb-serv-bootstrap-docker.asc
cat > "$temp_dir/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/deb-serv-bootstrap-docker.asc
EOF
install -m 0644 "$temp_dir/docker.sources" /etc/apt/sources.list.d/deb-serv-bootstrap-docker.sources
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if [[ ! -e /opt/docker ]]; then
    install -d -m 0750 /opt/docker
fi
[[ -d /opt/docker && ! -L /opt/docker ]] || die '/opt/docker must be a real directory.'
systemctl enable --now docker.service containerd.service ssh.service

if $root_ssh; then
    printf 'Explicit opt-in: enabling root SSH password authentication.\n'
    [[ $(passwd -S root | awk '{print $2}') == P ]] || die 'Root must already have a usable password; set it locally with passwd first.'
    [[ -f /etc/ssh/sshd_config && ! -L /etc/ssh/sshd_config ]] || die 'SSH configuration must be a regular file.'
    /usr/sbin/sshd -t
    install -d -m 0700 /var/backups/deb-serv-bootstrap
    ssh_backup=$(mktemp /var/backups/deb-serv-bootstrap/sshd_config-XXXXXXXX)
    cp -a /etc/ssh/sshd_config "$ssh_backup"
    # Global directives precede Includes; OpenSSH uses the first obtained value.
    {
        cat <<'EOF'
# BEGIN deb-serv-bootstrap managed SSH settings
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
# END deb-serv-bootstrap managed SSH settings
EOF
        sed '/^# BEGIN deb-serv-bootstrap managed SSH settings$/,/^# END deb-serv-bootstrap managed SSH settings$/d' "$ssh_backup"
    } > "$temp_dir/sshd_config"
    ssh_pending=true
    cat "$temp_dir/sshd_config" > /etc/ssh/sshd_config
    /usr/sbin/sshd -t
    /usr/sbin/sshd -T -C user=root > "$temp_dir/ssh-effective"
    grep -qx 'permitrootlogin yes' "$temp_dir/ssh-effective"
    grep -qx 'passwordauthentication yes' "$temp_dir/ssh-effective"
    grep -qx 'permitemptypasswords no' "$temp_dir/ssh-effective"
    grep -qx 'authenticationmethods any' "$temp_dir/ssh-effective"
    systemctl reload ssh.service
    systemctl is-active --quiet ssh.service
    ssh_pending=false
    printf 'SSH validated and reloaded. Backup: %s\n' "$ssh_backup"
fi

printf 'Running required health checks...\n'
/usr/sbin/sshd -t
systemctl is-active --quiet ssh.service docker.service containerd.service
docker info >/dev/null
docker compose version
docker buildx version
[[ -d /opt/docker && -w /opt/docker ]]
[[ -z $(dpkg --audit) ]] || die 'Package database audit reported unfinished package operations.'
failed_units=$(systemctl --failed --no-legend --plain)
if [[ -n $failed_units ]]; then
    printf 'WARNING: failed systemd units exist; review with systemctl --failed.\n'
fi
printf 'Bootstrap completed successfully. Log: %s\n' "$log_file"
if $reboot_after; then
    [[ -z $failed_units ]] || die 'Automatic reboot withheld because systemd has failed units.'
    printf 'Reboot requested explicitly.\n'
    systemctl reboot
else
    printf 'No automatic reboot. Consider a reboot after kernel or core system updates.\n'
fi
