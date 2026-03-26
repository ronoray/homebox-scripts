#!/bin/bash
# Homebox backup to Google Drive via rclone
# Prerequisites: rclone configured with a remote named "gdrive"
#   Run Option A: ssh -L 53682:localhost:53682 rono@192.168.68.105 then rclone authorize "drive"
#   Run Option B: rclone authorize "drive" on local machine and paste token
# Usage: ./backup-homebox.sh [--dry-run]
set -euo pipefail

REMOTE="gdrive:homebox-backups"
STAMP=$(date +%Y-%m-%d_%H%M)
TMPDIR=$(mktemp -d)
ARCHIVE="/tmp/homebox-backup-${STAMP}.tar.gz"
KEEP_BACKUPS=7

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; rm -rf "$TMPDIR"; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[[ "${1:-}" == "--dry-run" ]] && DRYRUN=1 || DRYRUN=0

# ── Sanity checks ─────────────────────────────────────────────────────────────
command -v rclone >/dev/null || die "rclone not found. Install: curl https://rclone.org/install.sh | sudo bash"
rclone listremotes | grep -q "^gdrive:" || die "rclone remote 'gdrive' not configured. Run: rclone config"

log "Starting homebox backup → ${REMOTE}/"
mkdir -p "${TMPDIR}/system" "${TMPDIR}/systemd" "${TMPDIR}/configs" "${TMPDIR}/scripts"

# ── 1. Core home/repo files ────────────────────────────────────────────────────
log "  system files..."
cp /home/rono/docker-compose.yml  "${TMPDIR}/system/"
cp /home/rono/.env                "${TMPDIR}/system/"
cp /home/rono/CLAUDE.md           "${TMPDIR}/system/" 2>/dev/null || true
cp /etc/fstab                     "${TMPDIR}/system/"
cp /etc/docker/daemon.json        "${TMPDIR}/system/" 2>/dev/null || true

# traefik file-provider (Home Assistant routing)
if [[ -d /home/rono/traefik-share ]]; then
    cp -a /home/rono/traefik-share "${TMPDIR}/system/traefik-share"
fi

# gluetun OpenVPN certs
if [[ -d /home/rono/gluetun-config ]]; then
    cp -a /home/rono/gluetun-config "${TMPDIR}/system/gluetun-config"
fi

# rclone config (so gdrive auth survives to next machine)
if [[ -f /home/rono/.config/rclone/rclone.conf ]]; then
    mkdir -p "${TMPDIR}/system/rclone"
    cp /home/rono/.config/rclone/rclone.conf "${TMPDIR}/system/rclone/"
fi

# SSH keys (public + private)
if [[ -d /home/rono/.ssh ]]; then
    mkdir -p "${TMPDIR}/system/ssh"
    cp /home/rono/.ssh/authorized_keys "${TMPDIR}/system/ssh/" 2>/dev/null || true
    cp /home/rono/.ssh/id_ed25519       "${TMPDIR}/system/ssh/" 2>/dev/null || true
    cp /home/rono/.ssh/id_ed25519.pub   "${TMPDIR}/system/ssh/" 2>/dev/null || true
    cp /home/rono/.ssh/config           "${TMPDIR}/system/ssh/" 2>/dev/null || true
fi

# sudoers drop-in
[[ -f /etc/sudoers.d/claude-code ]] && sudo cp /etc/sudoers.d/claude-code "${TMPDIR}/system/" 2>/dev/null || true

# ── 2. /home/rono/scripts (wstunnel binary + all service/script files) ─────────
log "  scripts dir..."
cp -a /home/rono/scripts "${TMPDIR}/scripts/homebox-scripts"

# ── 2a. HMS app (source + SQLite DB; skip node_modules/.next build artefacts) ──
log "  hms app..."
mkdir -p "${TMPDIR}/apps/hms"
rsync -a --exclude='node_modules' --exclude='.next' --exclude='*.tsbuildinfo' \
    /home/rono/hms/ "${TMPDIR}/apps/hms/"

# ── 2b. PWA configs (sab nginx proxy + manifests) ─────────────────────────────
log "  pwa configs..."
if [[ -d /home/rono/pwa ]]; then
    cp -a /home/rono/pwa "${TMPDIR}/apps/pwa"
fi

# WeeChat config (contains IRC keys in sec.conf)
if [[ -d /home/rono/.config/weechat ]]; then
    log "  weechat config..."
    cp -a /home/rono/.config/weechat "${TMPDIR}/system/weechat"
fi

# Claude memory (cross-session notes, settings, history, plans)
if [[ -d /home/rono/.claude ]]; then
    mkdir -p "${TMPDIR}/system/claude"
    cp -a /home/rono/.claude/projects          "${TMPDIR}/system/claude/" 2>/dev/null || true
    cp    /home/rono/.claude/settings.json     "${TMPDIR}/system/claude/" 2>/dev/null || true
    cp    /home/rono/.claude/settings.local.json "${TMPDIR}/system/claude/" 2>/dev/null || true
    cp    /home/rono/.claude/history.jsonl     "${TMPDIR}/system/claude/" 2>/dev/null || true
    cp -a /home/rono/.claude/plans             "${TMPDIR}/system/claude/" 2>/dev/null || true
    cp -a /home/rono/.claude/todos             "${TMPDIR}/system/claude/" 2>/dev/null || true
    # Telegram channel config (bot token, access list, approved users)
    cp -a /home/rono/.claude/channels          "${TMPDIR}/system/claude/" 2>/dev/null || true
    # Telegram MCP server (source + lock file, skip node_modules)
    if [[ -d /home/rono/.claude/telegram-channel ]]; then
        mkdir -p "${TMPDIR}/system/claude/telegram-channel"
        rsync -a --exclude='node_modules' --exclude='inbox' \
            /home/rono/.claude/telegram-channel/ "${TMPDIR}/system/claude/telegram-channel/"
    fi
fi

# ── 3. Systemd service files ──────────────────────────────────────────────────
log "  systemd services..."
for svc in wstunnel.service hms.service weechat.service cloudflared-mullvad-route.service docker-mullvad-bypass.service cloudflared-bypass.service clear-stale-gvfs.service post-fsck-reset.service; do
    f="/etc/systemd/system/${svc}"
    [[ -f "$f" ]] && cp "$f" "${TMPDIR}/systemd/" || true
done
# Docker drop-ins
mkdir -p "${TMPDIR}/systemd/docker.service.d"
cp /etc/systemd/system/docker.service.d/*.conf "${TMPDIR}/systemd/docker.service.d/" 2>/dev/null || true
# clear-stale-gvfs helper script
[[ -f /usr/local/sbin/clear-stale-gvfs.sh ]] && cp /usr/local/sbin/clear-stale-gvfs.sh "${TMPDIR}/systemd/" || true

# ── 4. App configs from /mnt/storage/docker ──────────────────────────────────
log "  app configs..."
APP_CONFIGS=(
    audiobookshelf bazarr calibre calibre-web
    gluetun homeassistant jellyseerr lazylibrarian
    lidarr organizr overseerr portainer
    prowlarr qbittorrent radarr sabnzbd
    sonarr tautulli traefik weechat
)

for app in "${APP_CONFIGS[@]}"; do
    src="/mnt/storage/docker/${app}"
    if [[ -d "$src" ]]; then
        log "    ${app}..."
        cp -a "$src" "${TMPDIR}/configs/${app}" 2>/dev/null || { warn "  ${app}: some files skipped (permission denied)"; true; }
    fi
done

# Misc files in /mnt/storage/docker root (resolv conf etc)
for f in /mnt/storage/docker/*.conf; do
    [[ -f "$f" ]] && cp "$f" "${TMPDIR}/configs/" || true
done

# ── 5. Plex — selective (skip Cache/Media/Metadata/Codecs, ~2-10 GB) ──────────
log "  plex (selective)..."
PLEX_SRC="/mnt/storage/docker/plex/Library/Application Support/Plex Media Server"
PLEX_DST="${TMPDIR}/configs/plex/Library/Application Support/Plex Media Server"
mkdir -p "${PLEX_DST}/Plug-in Support/Databases"

[[ -f "${PLEX_SRC}/Preferences.xml" ]] && \
    cp "${PLEX_SRC}/Preferences.xml" "${PLEX_DST}/"

for db in com.plexapp.plugins.library.db com.plexapp.plugins.library.blobs.db; do
    src="${PLEX_SRC}/Plug-in Support/Databases/${db}"
    [[ -f "$src" ]] && cp "$src" "${PLEX_DST}/Plug-in Support/Databases/"
done

# ── 6. Create archive ─────────────────────────────────────────────────────────
log "Creating archive..."
# Write manifest
find "${TMPDIR}" -type f | sort > "${TMPDIR}/manifest.txt"
FILE_COUNT=$(wc -l < "${TMPDIR}/manifest.txt")
log "  ${FILE_COUNT} files to archive"

tar -czf "$ARCHIVE" -C "$TMPDIR" .
SIZE=$(du -sh "$ARCHIVE" | cut -f1)
log "  Archive: $ARCHIVE ($SIZE)"

# ── 7. Upload to Google Drive ─────────────────────────────────────────────────
if [[ $DRYRUN -eq 1 ]]; then
    log "DRY RUN: would upload $ARCHIVE to ${REMOTE}/"
    log "DRY RUN: would prune old backups keeping last ${KEEP_BACKUPS}"
else
    log "Uploading to Google Drive..."
    rclone copy "$ARCHIVE" "${REMOTE}/" --progress

    log "Pruning old backups (keeping last ${KEEP_BACKUPS})..."
    mapfile -t ALL < <(rclone lsf "${REMOTE}/" | grep "^homebox-backup-" | sort)
    TO_DELETE=$(( ${#ALL[@]} - KEEP_BACKUPS ))
    if [[ $TO_DELETE -gt 0 ]]; then
        for old in "${ALL[@]:0:$TO_DELETE}"; do
            log "  Deleting: $old"
            rclone delete "${REMOTE}/${old}"
        done
    fi

    FILENAME=$(basename "$ARCHIVE")
    log "Upload complete: ${REMOTE}/${FILENAME}"

    # Always keep restore script standalone in Drive so a new machine can bootstrap
    rclone copy "$(realpath "$0")" "${REMOTE}/" 2>/dev/null || \
        rclone copy /home/rono/scripts/restore-homebox.sh "${REMOTE}/"
    log "Restore script updated at ${REMOTE}/restore-homebox.sh"

    # Push latest scripts to GitHub (ronoray/homebox-scripts) for curl bootstrap
    if command -v gh >/dev/null && gh auth status &>/dev/null; then
        GH_TOKEN=$(gh auth token 2>/dev/null) || true
        if [[ -n "$GH_TOKEN" ]]; then
            GHREPO_DIR=$(mktemp -d)
            git clone --quiet "https://x-access-token:${GH_TOKEN}@github.com/ronoray/homebox-scripts" "$GHREPO_DIR" 2>/dev/null && \
            cp /home/rono/scripts/backup-homebox.sh  "$GHREPO_DIR/" && \
            cp /home/rono/scripts/restore-homebox.sh "$GHREPO_DIR/" && \
            cd "$GHREPO_DIR" && \
            git config user.email "ronoray@users.noreply.github.com" && \
            git config user.name "ronoray" && \
            (git diff --quiet && git diff --cached --quiet) || \
                (git add -A && git commit -m "Auto-update from backup run ${STAMP}" && git push --quiet) && \
            cd /home/rono && rm -rf "$GHREPO_DIR" && \
            log "Scripts pushed to github.com/ronoray/homebox-scripts" || \
            { warn "GitHub push failed (non-fatal)"; rm -rf "$GHREPO_DIR" 2>/dev/null; cd /home/rono; }
        fi
    fi
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$TMPDIR" "$ARCHIVE"
log "Done."
