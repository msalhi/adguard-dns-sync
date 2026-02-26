# AdGuard DNS Sync - Go Version

This is a Go implementation of the `adguard-dns-sync.sh` script. It provides the same functionality with improved performance and portability.

⚠️ **Must run as `root` on the Proxmox host** (uses `pvesh`, `pct`, `qm` which require root privileges)

## Build

```bash
# Requirements: Go 1.21 or later
go build -o adguard-dns-sync-go main.go
```

## Usage

```bash
./adguard-dns-sync-go -H adguard -P 3000 -u myuser -p 'mypass' -D local -d -v
```

### Flags

- `-H` — AdGuard host (default: `adguard`)
- `-P` — AdGuard port (default: `3000`)
- `-u` — AdGuard username (required)
- `-p` — AdGuard password (required)
- `-D` — DNS suffix (default: empty)
- `-d` — Dry-run mode (show changes, no writes)
- `-v` — Verbose output

## Example

```bash
# Dry-run first
./adguard-dns-sync-go \
  -H 192.168.1.100 \
  -P 80 \
  -u admin \
  -p 'SecurePass!' \
  -D local \
  -d \
  -v

# If everything looks good, run for real
./adguard-dns-sync-go \
  -H 192.168.1.100 \
  -P 80 \
  -u admin \
  -p 'SecurePass!' \
  -D local
```

## Features

- **Add/Update/Delete** — Full sync with per-item approval prompts
- **Timestamped logs** — ISO 8601 format for audit trails and cron logging
- **Sync statistics** — Reports Added/Updated/Deleted/Skipped counts
- **Dry-run mode** — Preview all changes before applying
- **Per-item deletion** — Each orphaned rewrite gets individual confirmation (no all-or-nothing)
- **Error handling** — Validates HTTP status codes on all API calls
- **LXC + QEMU** support
- **Idempotent** — Safe to run repeatedly
- **Verbose logging** — Detailed operation trace with `-v` flag
- **No external dependencies** — Uses only Go standard library + native commands (pvesh, pct, qm)

## Example Output

```log
[2026-02-26 14:32:15] [INFO] Dry-run: yes
[2026-02-26 14:32:15] [INFO] Found 5 running containers/VMs
[2026-02-26 14:32:15] [INFO] want: plex -> 192.168.1.100
[2026-02-26 14:32:16] [INFO] want: jellyfin -> 192.168.1.101
[2026-02-26 14:32:16] [INFO] [DRY] add plex -> 192.168.1.100
[2026-02-26 14:32:16] [INFO] [DRY] add jellyfin -> 192.168.1.101
[2026-02-26 14:32:17] [INFO] Found 1 AdGuard rewrite(s) not present in Proxmox list
Delete old-app.local -> 192.168.1.50? [y/N] n
[2026-02-26 14:32:18] [INFO] skipped old-app.local -> 192.168.1.50
[2026-02-26 14:32:18] [INFO] Sync complete. Added: 2, Updated: 0, Deleted: 0, Skipped: 1. Manual DNS entries left untouched.
```

## Deletion Workflow

Unlike the original bash script, the Go version **asks for confirmation on each deletion individually**:

```bash
Delete old-db.local -> 192.168.1.50? [y/N] y   # Delete this one
Delete stale-app.local -> 192.168.1.60? [y/N] n  # Keep this one
```

No automatic deletions—perfect for cron jobs!

## Building

```bash
# Build
go build -o /usr/local/bin/adguard-dns-sync-go main.go

# Create service file
sudo tee /etc/systemd/system/adguard-dns-sync.service > /dev/null <<EOF
[Unit]
Description=AdGuard DNS Sync for Proxmox
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/adguard-dns-sync-go -H adguard -P 3000 -u admin -p 'yourpass' -D local
StandardInput=tty
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create timer (runs daily)
sudo tee /etc/systemd/system/adguard-dns-sync.timer > /dev/null <<EOF
[Unit]
Description=Daily AdGuard DNS Sync

[Timer]
OnCalendar=daily
OnCalendar=*-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable adguard-dns-sync.timer
sudo systemctl start adguard-dns-sync.timer

# Check status
sudo systemctl status adguard-dns-sync.timer
sudo journalctl -u adguard-dns-sync.service -f
```

## Differences from Bash Version

| Feature | Bash | Go |
| --------- | ------ | ----- |
| Performance | Slower (spawns many subprocesses) | Faster (native binary) |
| Dependencies | jq, curl, pvesh, pct, qm | Only pvesh, pct, qm (native commands) |
| Binary size | ~5 KB script | ~8 MB binary (includes Go runtime) |
| Memory | Low | Low |
| Cross-platform | Linux only (depends on Proxmox) | Linux only (depends on Proxmox) |

## Troubleshooting

### "pvesh not found"

- Run on a Proxmox node where `pvesh` is available

### "Cannot reach AdGuard"

- Check hostname/port/credentials
- Ensure AdGuard API is accessible from the Proxmox host

### IP not detected for container

- Use `-v` flag to see detailed logs
- Verify container has network IP: `pct exec <vmid> -- hostname -I`

## Building for Different Architectures

```bash
# Build for amd64
GOOS=linux GOARCH=amd64 go build -o adguard-dns-sync-go-amd64 main.go

# Build for arm64 (Raspberry Pi, ARM servers)
GOOS=linux GOARCH=arm64 go build -o adguard-dns-sync-go-arm64 main.go
```
