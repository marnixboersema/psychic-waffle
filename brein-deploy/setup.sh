#!/usr/bin/env bash
# Brein bootstrap — idempotent. Run as root on a fresh Ubuntu 24.04 VPS.
#   curl -fsSL https://raw.githubusercontent.com/.../setup.sh | bash
# or:
#   bash setup.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	echo "Run as root (sudo -i, then bash setup.sh)" >&2
	exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
	echo "Warning: tested on Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}" >&2
fi

log() { printf '\n\033[1;34m[setup]\033[0m %s\n' "$*"; }

# NB: do NOT call `cloud-init status --wait` here. When this script is invoked
# from cloud-init's runcmd (via brein-bootstrap.sh), --wait deadlocks because
# cloud-init can't finish until runcmd returns, and runcmd can't return until
# --wait returns. When run manually post-boot, cloud-init has already finished
# anyway. Retry on transient apt-lock races (unattended-upgrades first-boot).

log "Updating apt + base packages"
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3 4 5; do
	apt-get update -y && break
	log "apt-get update attempt $i failed, retrying in 5s..."
	sleep 5
done
apt-get install -y \
	ca-certificates curl gnupg lsb-release \
	ufw fail2ban unattended-upgrades \
	debian-keyring debian-archive-keyring apt-transport-https \
	jq

# -----------------------------------------------------------------------------
# Docker — official repo
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
	log "Installing Docker from official repo"
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
	apt-get update -y
	apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	systemctl enable --now docker
else
	log "Docker already installed: $(docker --version)"
fi

# -----------------------------------------------------------------------------
# Caddy — official Cloudsmith repo
# -----------------------------------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
	log "Installing Caddy from official repo"
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
		> /etc/apt/sources.list.d/caddy-stable.list
	apt-get update -y
	apt-get install -y caddy
	systemctl enable --now caddy
else
	log "Caddy already installed: $(caddy version)"
fi

# -----------------------------------------------------------------------------
# Swapfile — 2 GB. CX22 ships with none; Open WebUI can spike during ingest.
# -----------------------------------------------------------------------------
if [[ ! -f /swapfile ]]; then
	log "Creating 2 GB swapfile"
	fallocate -l 2G /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	swapon /swapfile
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	sysctl -w vm.swappiness=10 >/dev/null
	grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
else
	log "Swapfile already present"
fi

# -----------------------------------------------------------------------------
# UFW — only 22, 80, 443. Defence in depth alongside Hetzner Cloud Firewall.
# -----------------------------------------------------------------------------
log "Configuring UFW"
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

# -----------------------------------------------------------------------------
# fail2ban — sshd jail with sensible defaults
# -----------------------------------------------------------------------------
log "Configuring fail2ban (sshd jail)"
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port    = ssh
backend = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# -----------------------------------------------------------------------------
# Unattended security upgrades
# -----------------------------------------------------------------------------
log "Enabling unattended-upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Reboot at 04:30 if a kernel upgrade requires it (after backup window).
sed -i \
	-e 's|^//\s*Unattended-Upgrade::Automatic-Reboot\s.*|Unattended-Upgrade::Automatic-Reboot "true";|' \
	-e 's|^//\s*Unattended-Upgrade::Automatic-Reboot-Time\s.*|Unattended-Upgrade::Automatic-Reboot-Time "04:30";|' \
	/etc/apt/apt.conf.d/50unattended-upgrades
systemctl enable --now unattended-upgrades

# -----------------------------------------------------------------------------
# Working directories
# -----------------------------------------------------------------------------
log "Creating /opt/brein, /var/backups/brein, /var/lib/brein/static"
install -d -m 0755 /opt/brein
install -d -m 0750 /var/backups/brein
install -d -m 0755 /var/lib/brein/static

log "Bootstrap complete. Next:"
cat <<'EOF'

  1. Copy this repo's brein-deploy/ files into /opt/brein/:
       cp -r ./* /opt/brein/
  2. Create /opt/brein/.env from .env.example and fill in secrets:
       cd /opt/brein && cp .env.example .env
       openssl rand -hex 32        # paste as WEBUI_SECRET_KEY
       ${EDITOR:-nano} .env
  3. Drop PWA icons into /var/lib/brein/static/:
       icon-192.png, icon-512.png, apple-touch-icon.png
       (manifest.webmanifest is already in the brein-deploy/static/ folder)
       cp /opt/brein/static/manifest.webmanifest /var/lib/brein/static/
  4. Install the Caddyfile:
       cp /opt/brein/Caddyfile /etc/caddy/Caddyfile
       systemctl reload caddy
  5. Start Open WebUI:
       cd /opt/brein && docker compose up -d
  6. Install the weekly backup cron:
       crontab -l 2>/dev/null > /tmp/cron.tmp || true
       cat /opt/brein/crontab.txt >> /tmp/cron.tmp
       crontab /tmp/cron.tmp && rm /tmp/cron.tmp

EOF
