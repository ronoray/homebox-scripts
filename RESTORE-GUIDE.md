# Homebox Restore Guide
**Last updated:** 2026-03-17
**Machine:** rono-desktop (homebox) — home media server
**Owner:** ronoray / admin@hungrytimes.in

---

## ⚡ TL;DR — Full Restore in 5 Steps

```bash
# 1. Install rclone
curl https://rclone.org/install.sh | sudo bash

# 2. Restore rclone config (gdrive auth) — see section below
#    Skip this if you already have rclone configured with a "gdrive" remote

# 3. Pull and run the restore script
rclone copy gdrive:homebox-backups/restore-homebox.sh .
bash restore-homebox.sh gdrive

# 4. (Alternative — if restore script itself is gone, pull from GitHub)
curl -fsSL https://raw.githubusercontent.com/ronoray/homebox-scripts/master/restore-homebox.sh | bash -s -- gdrive

# 5. Follow the manual steps printed at the end of the restore script
```

---

## 🔑 Step 0 — Restore rclone / Google Drive Auth

The backup archive contains `system/rclone/rclone.conf` which is restored automatically
by the restore script. But to *run* the restore script you need rclone configured first.

**Option A — You have the rclone.conf file** (e.g. copied off another device):
```bash
mkdir -p ~/.config/rclone
cp rclone.conf ~/.config/rclone/rclone.conf
```

**Option B — Re-authenticate from scratch** (takes ~2 minutes):
```bash
rclone config
# → New remote → Name: gdrive → Type: drive (Google Drive)
# → Leave client_id/secret blank → scope: 1 (full access)
# → Use auto config: Yes → browser opens → log in as ronoray@gmail.com or admin@hungrytimes.in
# → Confirm token → done
```

**Option C — Headless server (no browser)**:
```bash
# On any other machine with a browser, run:
rclone authorize "drive"
# Copy the token it prints, paste it into the config on the server
```

---

## 🤖 Claude Code — First Session Introduction

After restore, open Claude Code in `/home/rono` and paste this as your first message:

---
> I've just restored my homebox (home media server) from backup. The CLAUDE.md in this
> directory has the full architecture. Here's a quick summary:
>
> - **Stack**: Docker Compose, ~25 services (Plex, Radarr, Sonarr, SABnzbd, qBittorrent,
>   Lidarr, Bazarr, Prowlarr, Traefik, Calibre, Jellyseerr, Organizr, etc.)
> - **Storage**: 4× HDDs in /mnt/disk1–4 pooled by mergerfs → /mnt/storage; Docker config
>   in /mnt/storage/docker/, media in /mnt/storage/media/
> - **VPN**: gluetun (OpenVPN over TCP 8443 → droplet 64.227.137.98) for downloads;
>   WireGuard over wstunnel WebSocket for Plex remote access
> - **Tunnel**: wstunnel-client → wss://wg.hungrytimes.in → WireGuard IPs 10.8.0.2 (homebox) / 10.8.0.1 (droplet)
> - **Plex remote**: plex.hungrytimes.in → droplet Traefik → plex-proxy nginx → WG 10.8.0.2:32400
> - **Backups**: daily to gdrive:homebox-backups/ via rclone, scripts at github.com/ronoray/homebox-scripts
> - **IRC**: WeeChat in tmux session "chat" — servers: filelist, ar, synirc, ptp
> - **Custom apps**: HMS (household management, Next.js + SQLite at /home/rono/hms/),
>   GD music dashboard (Grateful Dead pipeline, scripts in /home/rono/scripts/gd-*.sh)
> - **PWA proxies**: nginx PWAs in /home/rono/pwa/ (sab, qbit, etc.)
> - **Domain**: hungrytimes.in (Cloudflare DNS), tunnels via cloudflared
> - **Key constraint**: ISP is CGNAT, blocks all UDP and non-standard TCP — only TCP 22/80/443/8443 reach the droplet
> - **DO NOT touch**: droplet's other services (ops-panel, customer site, invest-copilot, sales-bot)
>
> Please read CLAUDE.md for full details before making any changes.

---

## 🔧 Manual Steps After Running restore-homebox.sh

The restore script will remind you, but here's the full checklist:

### 1. Mount Storage Disks
```bash
# Disks must be physically connected — UUIDs in /etc/fstab must match
sudo systemctl daemon-reload
sudo mount -a
# Verify:
df -h /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/disk4 /mnt/storage
```

⚠️ **disk4 note**: The 9.1TB Seagate USB drive (disk4) had bad sectors detected at the
~8.8TB mark as of 2026-03-17. Data near the start of the disk (where Docker configs live)
is fine. Monitor it and consider replacing when convenient.

### 2. Install & Connect Mullvad VPN
```bash
curl -fsSL https://repository.mullvad.net/deb/mullvad-keyring.asc | sudo gpg --dearmor -o /usr/share/keyrings/mullvad-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/mullvad-keyring.gpg] https://repository.mullvad.net/deb/stable stable main' | sudo tee /etc/apt/sources.list.d/mullvad.list
sudo apt update && sudo apt install mullvad-vpn
mullvad account login <your-account-number>
mullvad lan set allow
mullvad connect
```

### 3. Start WireGuard / wstunnel
```bash
sudo systemctl enable --now wstunnel.service
# Verify tunnel is up:
ping -c 3 10.8.0.1
```

### 4. Install NVIDIA Drivers (for Plex GPU transcoding)
```bash
sudo apt install nvidia-driver-470 nvidia-container-toolkit
sudo systemctl restart docker
# Verify:
nvidia-smi
```

### 5. Install GitHub CLI & Re-authenticate
```bash
# Install gh (needed for backup script auto-push)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/gh.gpg
sudo mv /tmp/gh.gpg /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update && sudo apt install gh
# Authenticate (uses GitHub Mobile device flow — no browser needed):
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
```

### 6. Create Docker Networks
```bash
docker network create compose_media-net
# vpn-net is managed by gluetun — it's created when gluetun starts
```

### 7. Start the Stack
```bash
cd /home/rono
docker compose pull
docker compose up -d
docker compose ps
```

### 8. Start WeeChat
```bash
sudo systemctl enable --now weechat.service
# Verify:
tmux attach -t chat
# Should show: filelist (PhreakyPhool), ar (PhreakPhool), synirc (PhreakyPhool), ptp (phreakyphool)
```

### 9. Restore HMS App
```bash
cd /home/rono/hms
npm install
# The systemd service handles startup:
sudo systemctl enable --now hms.service
```

### 10. Plex Post-Restore
- Open Plex UI → Settings → Troubleshooting → **Clean Bundles**, then **Empty Trash**
- Check library scans complete correctly
- Re-verify plex.hungrytimes.in remote access works (depends on WireGuard being up)

### 11. Set Up Backup Cron (if not auto-restored)
```bash
# Run backup daily at 3am
(crontab -l 2>/dev/null; echo "0 3 * * * /home/rono/scripts/backup-homebox.sh >> /home/rono/logs/backup.log 2>&1") | crontab -
```

---

## 📦 What's in the Backup

| Location in archive | Source |
|---|---|
| `system/docker-compose.yml` | Full stack definition |
| `system/.env` | All secrets & env vars |
| `system/CLAUDE.md` | Claude Code project context |
| `system/fstab` | Disk mount config |
| `system/rclone/rclone.conf` | GDrive auth token |
| `system/ssh/` | SSH keys (id_ed25519, authorized_keys, config) |
| `system/gluetun-config/` | OpenVPN certs for VPN |
| `system/traefik-share/` | Traefik file provider (HA routing, GD music) |
| `system/weechat/` | WeeChat config + IRC keys |
| `system/claude/` | Claude memory (projects, settings, history) |
| `scripts/homebox-scripts/` | All scripts + wstunnel binary |
| `apps/hms/` | HMS app source + SQLite DB |
| `apps/pwa/` | PWA nginx proxy configs |
| `systemd/` | wstunnel, hms, weechat, cloudflared service files |
| `configs/<app>/` | All Docker app configs (radarr, sonarr, plex DB, etc.) |

**Not backed up** (too large): Media files in /mnt/storage/media/ — these are re-downloaded.

---

## 🗂 Key Locations

| Thing | Location |
|---|---|
| Backup archives | `gdrive:homebox-backups/` (last 7 kept) |
| Restore script | `gdrive:homebox-backups/restore-homebox.sh` |
| Scripts on GitHub | `github.com/ronoray/homebox-scripts` |
| This guide | `gdrive:RESTORE-GUIDE.md` |
| Droplet IP | 64.227.137.98 |
| Homebox LAN IP | 192.168.68.105 |
| WireGuard IPs | homebox=10.8.0.2, droplet=10.8.0.1 |
| Domain | hungrytimes.in (Cloudflare) |

---

## 💡 Recommendations

1. **Save this file on your phone** — Download from Google Drive and save offline in
   Google Keep or Files app so it's accessible even without internet.

2. **Bookmark gdrive:homebox-backups** in the Google Drive Android app — star the folder
   so it's always one tap away.

3. **Keep the GitHub repo URL somewhere** — `github.com/ronoray/homebox-scripts`
   is the zero-dependency bootstrap (just needs `curl`).

4. **Store Mullvad account number** in your password manager — it's needed for step 2
   and isn't in the backup.

5. **disk4 health** — The 9.1TB Seagate USB drive had I/O errors at the ~8.8TB mark
   (2026-03-17). Get a replacement drive and migrate when convenient. Run:
   `sudo dmesg | grep -i "sdf\|error\|sector"` to check current status.

6. **Consider encrypting backups** — The archive contains SSH keys, WeeChat IRC keys,
   and rclone tokens. Adding `--crypt` to the rclone remote would protect these.
