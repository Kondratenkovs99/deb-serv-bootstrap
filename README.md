# deb-serv-bootstrap

A reusable Bash bootstrap for Debian 13 (Trixie) servers. It updates the system, installs administration tools and Docker Engine with the Compose plugin, and validates core services before reporting success.

## Features

- System package index refresh and full upgrade, preserving existing configuration files when prompted by package upgrades.
- Administration tools: sudo, Git, Vim, htop, tmux, jq, unzip, rsync, lsof, DNS utilities, and network/process tools.
- Docker Engine, CLI, containerd, Buildx, and Docker Compose from Docker's official signed Debian repository. Compose uses the `docker compose` v2 command interface; the script installs the current repository release rather than pinning a major version.
- A root-owned `/opt/docker` directory for Compose projects on a fresh installation. Existing directory permissions are preserved.
- Optional root SSH password authentication, with a configuration backup, syntax and effective-setting checks, and rollback if validation or reload fails.
- Private per-run logs, concurrent-run prevention, package and service health checks, and an explicitly requested reboot.

## Requirements

Use a Debian 13 installation with Bash, systemd, working Debian APT sources, network access to package repositories, and root privileges. Initial installations should have no conflicting container packages or independently configured Docker repository entries. The script stops rather than removing them automatically.

Review [bootstrap.sh](bootstrap.sh) before running it. A full upgrade can replace or remove packages and restart services; use a maintenance window and a system backup. For remote administration, retain the current SSH session and have console access available.

## Run locally

Download this repository using its **Code → Download ZIP** menu, extract it, and open a terminal in the extracted directory. Alternatively, use an existing local clone. No repository URL or personal configuration needs to be edited.

```bash
bash -n bootstrap.sh
sudo bash bootstrap.sh
```

From an existing Git clone, update it before running when appropriate:

```bash
git pull --ff-only
sudo bash bootstrap.sh
```

If already running as root, omit `sudo`. On a minimal installation without sudo, switch to root with `su`, return to the extracted directory, and run `bash bootstrap.sh`.

### Optional root SSH password login

The default run preserves SSH authentication settings. Enabling root password login increases exposure; key-based access through a regular administrator account is preferable for publicly reachable systems.

Set a root password locally with `sudo passwd root` if needed. The script neither supplies nor records passwords. Then explicitly opt in:

```bash
sudo bash bootstrap.sh --enable-root-password-ssh
```

The script prepends global managed settings to `/etc/ssh/sshd_config`, permitting root login and password authentication while rejecting empty passwords. Password authentication is also enabled for other accounts unless their connection-specific rules override it. Existing multi-factor authentication requirements are preserved; the opt-in stops and rolls back if the evaluated root policy requires more than a single authentication method. Other access controls, PAM policies, and connection-specific rules may still restrict login. Local validation does not prove end-to-end remote access; test a second session before closing the original one.

Each change saves the previous main configuration under `/var/backups/deb-serv-bootstrap/`. Includes are preserved. Failed validation or reload restores the previous file and attempts a validated reload. Repeating the opt-in replaces its managed block instead of adding duplicate blocks. Running without the flag later does not undo a previous opt-in.

To restore a prior policy, inspect the backups, select the intended one, restore it to `/etc/ssh/sshd_config`, run `sudo /usr/sbin/sshd -t`, and reload with `sudo systemctl reload ssh`. Alternatively, remove the marked managed block and validate before reloading. Keep console access available during recovery.

### Optional reboot

```bash
sudo bash bootstrap.sh --reboot
```

Options may be combined. Reboot occurs only after required checks pass and no failed systemd units are reported. Without this flag, the script never requests a reboot.

## Verification and logs

Required checks validate SSH syntax, active SSH/Docker/containerd services, Docker daemon access, Compose and Buildx availability, `/opt/docker`, and package database consistency. Failed systemd units produce a warning and prevent an opted-in reboot. The script does not pull or run a demonstration container.

```bash
sudo systemctl is-active ssh docker containerd
sudo docker info
sudo docker compose version
sudo docker buildx version
sudo dpkg --audit
sudo systemctl --failed
```

Logs are stored in `/var/log/deb-serv-bootstrap/` with root-only access. Runtime output and SSH backups can contain information from the machine on which the script runs; keep them private and review them before sharing. No runtime logs or configuration backups belong in the public repository.

## Scope and repeat runs

Designed for initial provisioning, with repeat runs supported for package updates and the script-managed Docker repository. It installs current package versions, so repeat runs may upgrade Docker. It does not create users, set passwords, rename the machine, configure networking or a firewall, deploy workloads, or add users to the Docker group. Docker socket access grants extensive system privileges.

Docker may publish container ports through its own firewall rules; review exposure before deploying workloads. `/opt/docker` is a workspace convention, not a change to Docker's storage directory.

On error, the script exits nonzero and keeps its log. Package and repository changes are not transactional and are not automatically rolled back. Diagnose the error before retrying. SSH rollback applies only while its configuration change is being validated and reloaded.

The distributed files contain no personal identifiers, credentials, private addresses, or machine-specific settings. The script's public Docker download endpoint is necessary for the official repository installation.

## License

MIT. See the repository's [LICENSE](LICENSE) file.
