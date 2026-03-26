#!/bin/bash
# Homebox restore script — full machine rebuild from backup
#
# Usage:
#   ./restore-homebox.sh <path-to-backup.tar.gz>          # from local file
#   ./restore-homebox.sh gdrive                            # pull latest from Google Drive
#
# On a brand-new machine (rclone not yet configured):
#   1. Install rclone:  curl https://rclone.org/install.sh | sudo bash
#   2. Configure gdrive remote:  rclone config   (choose Google Drive, name it "gdrive")
#   3. Then run: ./restore-homebox.sh gdrive
#
set -euo pipefail

REMOTE="gdrive:homebox-backups"
TMPDIR=$(mktemp -d)
TARGET_USER="${SUDO_USER:-rono}"
TARGET_HOME="/home/${TARGET_USER}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; rm -rf "$TMPDIR"; exit 1; }
ask()  { read -rp "$1 [y/N] " _ans; [[ "${_ans,,}" == "y" ]]; }

[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

ARCHIVE="${1:-}"
[[ -z "$ARCHIVE" ]] && die "Usage: $0 <backup.tar.gz | gdrive>"

# ── Step 0: Get the archive ───────────────────────────────────────────────────
if [[ "$ARCHIVE" == "gdrive" ]]; then
    command -v rclone >/dev/null || die "rclone not installed. Run: curl https://rclone.org/install.sh | sudo bash"
    rclone listremotes | grep -q "^gdrive:" || die "rclone 'gdrive' remote not configured. Run: rclone config"
    log "Finding latest backup on Google Drive..."
    LATEST=$(rclone lsf "${REMOTE}/" | grep "^homebox-backup-" | sort | tail -1)
    [[ -z "$LATEST" ]] && die "No backups found at ${REMOTE}/"
    log "Downloading: ${LATEST} ..."
    rclone copy "${REMOTE}/${LATEST}" "$TMPDIR/"
    ARCHIVE="${TMPDIR}/${LATEST}"
fi

[[ -f "$ARCHIVE" ]] || die "Archive not found: $ARCHIVE"

log "Extracting ${ARCHIVE}..."
EXTRACT="${TMPDIR}/extracted"
mkdir -p "$EXTRACT"
tar -xzf "$ARCHIVE" -C "$EXTRACT"

# ── Step 1: Install base dependencies ────────────────────────────────────────
log "Installing base dependencies..."
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
    docker.io docker-compose-plugin \
    mergerfs attr \
    curl wget git \
    wireguard-tools \
    2>&1 | tail -5

# Install rclone if missing
if ! command -v rclone &>/dev/null; then
    curl -fsSL https://rclone.org/install.sh -o /tmp/rclone-install.sh
    $SUDO bash /tmp/rclone-install.sh 2>&1 | tail -3
fi

# ── Step 2: Restore system files ─────────────────────────────────────────────
log "Restoring system files..."
mkdir -p "$TARGET_HOME"

[[ -f "${EXTRACT}/system/docker-compose.yml" ]] && cp "${EXTRACT}/system/docker-compose.yml" "$TARGET_HOME/"
[[ -f "${EXTRACT}/system/.env" ]]               && cp "${EXTRACT}/system/.env" "$TARGET_HOME/"
[[ -f "${EXTRACT}/system/CLAUDE.md" ]]          && cp "${EXTRACT}/system/CLAUDE.md" "$TARGET_HOME/"

# fstab — show diff, ask before replacing
if [[ -f "${EXTRACT}/system/fstab" ]]; then
    log "fstab from backup (review before accepting):"
    cat "${EXTRACT}/system/fstab"
    if ask "Replace /etc/fstab with backed-up version?"; then
        $SUDO cp "${EXTRACT}/system/fstab" /etc/fstab
        log "  fstab restored."
    fi
fi

# docker daemon config
if [[ -f "${EXTRACT}/system/daemon.json" ]]; then
    $SUDO mkdir -p /etc/docker
    $SUDO cp "${EXTRACT}/system/daemon.json" /etc/docker/daemon.json
    log "  /etc/docker/daemon.json restored."
fi

# traefik file provider (Home Assistant)
if [[ -d "${EXTRACT}/system/traefik-share" ]]; then
    cp -a "${EXTRACT}/system/traefik-share" "$TARGET_HOME/traefik-share"
    log "  traefik-share restored."
fi

# gluetun OpenVPN certs
if [[ -d "${EXTRACT}/system/gluetun-config" ]]; then
    cp -a "${EXTRACT}/system/gluetun-config" "$TARGET_HOME/gluetun-config"
    log "  gluetun-config restored."
fi

# rclone config
if [[ -f "${EXTRACT}/system/rclone/rclone.conf" ]]; then
    mkdir -p "$TARGET_HOME/.config/rclone"
    cp "${EXTRACT}/system/rclone/rclone.conf" "$TARGET_HOME/.config/rclone/"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/.config/rclone"
    log "  rclone config restored."
fi

# SSH keys
if [[ -d "${EXTRACT}/system/ssh" ]]; then
    mkdir -p "$TARGET_HOME/.ssh"
    cp -a "${EXTRACT}/system/ssh/." "$TARGET_HOME/.ssh/"
    chmod 700 "$TARGET_HOME/.ssh"
    chmod 600 "$TARGET_HOME/.ssh/"* 2>/dev/null || true
    chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/.ssh"
    log "  SSH keys restored."
fi

# sudoers drop-in
if [[ -f "${EXTRACT}/system/claude-code" ]]; then
    $SUDO cp "${EXTRACT}/system/claude-code" /etc/sudoers.d/claude-code
    $SUDO chmod 440 /etc/sudoers.d/claude-code
    log "  sudoers drop-in restored."
fi

# WeeChat config
if [[ -d "${EXTRACT}/system/weechat" ]]; then
    mkdir -p "$TARGET_HOME/.config/weechat"
    cp -a "${EXTRACT}/system/weechat/." "$TARGET_HOME/.config/weechat/"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/.config/weechat"
    log "  weechat config restored."
fi

# Claude memory (projects, settings, history, plans, todos, Telegram channel)
if [[ -d "${EXTRACT}/system/claude" ]]; then
    mkdir -p "$TARGET_HOME/.claude"
    cp -a "${EXTRACT}/system/claude/." "$TARGET_HOME/.claude/"
    # Re-install Telegram MCP node_modules after restore
    if [[ -d "$TARGET_HOME/.claude/telegram-channel" ]]; then
        log "  Installing Telegram MCP dependencies..."
        cd "$TARGET_HOME/.claude/telegram-channel"
        npm install --silent 2>/dev/null || true
        cd /
    fi
    chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/.claude"
    log "  Claude memory/settings + Telegram channel restored."
fi

# ── Step 3: Restore scripts (wstunnel binary etc.) ────────────────────────────
if [[ -d "${EXTRACT}/scripts/homebox-scripts" ]]; then
    mkdir -p "$TARGET_HOME/scripts"
    cp -a "${EXTRACT}/scripts/homebox-scripts/." "$TARGET_HOME/scripts/"
    chmod +x "$TARGET_HOME/scripts/"*.sh "$TARGET_HOME/scripts/wstunnel" 2>/dev/null || true
    chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/scripts"
    log "  scripts dir restored (wstunnel binary + service files)."
fi

# ── Step 4: Restore systemd services ─────────────────────────────────────────
if [[ -d "${EXTRACT}/systemd" ]]; then
    log "Restoring systemd services..."
    for svc in "${EXTRACT}/systemd/"*.service; do
        name=$(basename "$svc")
        $SUDO cp "$svc" "/etc/systemd/system/${name}"
        log "  Installed: ${name}"
    done
    # Symlink wstunnel.service from scripts dir if it exists there
    [[ -f "$TARGET_HOME/scripts/wstunnel.service" ]] && \
        $SUDO ln -sf "$TARGET_HOME/scripts/wstunnel.service" /etc/systemd/system/wstunnel.service 2>/dev/null || true
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable wstunnel.service cloudflared-mullvad-route.service 2>/dev/null || true
    log "  Services enabled."
fi

# ── Step 5: Mount points ──────────────────────────────────────────────────────
log "Creating mount points..."
$SUDO mkdir -p /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/disk4 /mnt/storage

# ── Step 6: Restore app configs ──────────────────────────────────────────────
log "Restoring app configs to /mnt/storage/docker/..."
$SUDO mkdir -p /mnt/storage/docker

if [[ -d "${EXTRACT}/configs" ]]; then
    $SUDO cp -a "${EXTRACT}/configs/." /mnt/storage/docker/
    $SUDO chown -R "${TARGET_USER}:${TARGET_USER}" /mnt/storage/docker/
    log "  Restored: $(ls "${EXTRACT}/configs/" | tr '\n' ' ')"
fi

# ── Step 7: Create Docker networks ────────────────────────────────────────────
log "Creating Docker networks..."
docker network create compose_media-net 2>/dev/null && log "  compose_media-net created" || log "  compose_media-net already exists"

# ── Step 8: Start containers ──────────────────────────────────────────────────
if [[ -f "$TARGET_HOME/docker-compose.yml" ]]; then
    log "Pulling images and starting containers..."
    cd "$TARGET_HOME"
    docker compose pull 2>&1 | tail -5
    docker compose up -d
    log "  Containers started."
else
    log "WARNING: docker-compose.yml not found, skipping container start."
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$TMPDIR"

log ""
log "══════════════════════════════════════════════════════════════"
log "Restore complete. MANUAL steps still required:"
log ""
log "  1. Mount storage disks:"
log "       sudo systemctl daemon-reload && sudo mount -a"
log "       (drives must be physically connected with same UUIDs)"
log ""
log "  2. Install Mullvad VPN (handles host-level VPN):"
log "       curl -fsSL https://repository.mullvad.net/deb/mullvad-keyring.asc | sudo gpg --dearmor -o /usr/share/keyrings/mullvad-keyring.gpg"
log "       echo 'deb [signed-by=/usr/share/keyrings/mullvad-keyring.gpg] https://repository.mullvad.net/deb/stable stable main' | sudo tee /etc/apt/sources.list.d/mullvad.list"
log "       sudo apt update && sudo apt install mullvad-vpn"
log "       mullvad account login <your-account-number>"
log "       mullvad lan set allow"
log "       mullvad connect"
log ""
log "  3. Start wstunnel (after Mullvad is connected):"
log "       sudo systemctl start wstunnel.service"
log ""
log "  4. NVIDIA drivers (for Plex GPU transcoding):"
log "       sudo apt install nvidia-driver-470"
log "       sudo apt install nvidia-container-toolkit"
log "       (then: sudo systemctl restart docker)"
log ""
log "  5. Verify containers healthy:"
log "       docker compose ps"
log "       docker compose logs -f plex"
log ""
log "  6. In Plex UI → Settings → Troubleshooting → 'Clean Bundles'"
log "     and 'Empty Trash' after verifying library looks correct."
log "══════════════════════════════════════════════════════════════"
