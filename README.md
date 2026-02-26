# AdGuard DNS Sync for Proxmox

**Syncs Proxmox containers/VMs to AdGuardHome DNS rewrites automatically.**

Scans LXCs/VMs hostnames and IPs to creates DNS entries like `plex → 192.168.1.100` automatically to AdGuardHome's DNS rewrites so you can access containers by name anywhere on your network.

## Features

- ✅ **Add/update/delete** - syncs all changes with approval confirmation
- ✅ **Per-item deletion prompts** - asks once per orphaned rewrite before deleting
- ✅ **Timestamped logs** - every event includes date/time for audit trails
- ✅ **Sync statistics** - shows Added/Updated/Deleted/Skipped counts at the end
- ✅ **LXC + QEMU** support
- ✅ **Idempotent** - safe to run repeatedly
- ✅ **Dry-run mode** (`-d`) - preview all changes without writing
- ✅ **Bash + Go** versions available (identical behavior)
- ✅ **Production-ready** - works with cron.daily/systemd
- ✅ **Error handling** - validates HTTP responses and reports failures
- ✅ **Secure** - root-only, credentials not logged

## Requirements

- ⚠️ **Must run as `root` on a Proxmox host** (uses `pvesh`, `pct`, `qm` which require root privileges)
- AdGuard Home accessible via HTTP API
- `jq`, `curl`, `pct`, `qm` (standard on Proxmox)

## Quick Start

⚠️ **Run as root on the Proxmox host** (`su -` or `sudo bash`)

### 1. Download and install

```bash
cd /root/

# Download the script
git clone https://github.com/msalhi/adguard-dns-sync.git

cd adguard-dns-sync
chmod +x adguard-dns-sync.sh
```

### 2. Test it

```bash
# Dry-run first (no changes)
./adguard-dns-sync.sh \
  -H adguard \
  -P 3000 \
  -u USERNAME \
  -p 'PASSWORD' \
  -d

# Run for real
./adguard-dns-sync.sh \
  -H adguard \
  -P 3000 \
  -u USERNAME \
  -p 'PASSWORD'
```

**Expected output:**

```log
[2026-02-26 14:32:15] [INFO] Dry-run: yes
[2026-02-26 14:32:15] [INFO] Found 3 running containers/VMs
[2026-02-26 14:32:15] [INFO] want: plex -> 192.168.1.100
[2026-02-26 14:32:15] [INFO] want: jellyfin -> 192.168.1.101
[2026-02-26 14:32:15] [INFO] [DRY] add plex -> 192.168.1.100
[2026-02-26 14:32:15] [INFO] [DRY] add jellyfin -> 192.168.1.101
[2026-02-26 14:32:15] [INFO] Sync complete. Added: 2, Updated: 0, Deleted: 0, Skipped: 0. Manual DNS entries left untouched.
```

### 3. Setup automation (cron.daily)

```bash
# Run setup (creates everything)
chmod +x adguard-dns-setup.sh
sudo ./adguard-dns-setup.sh
```

This creates:

- `/etc/adguard-dns-sync.conf` (edit your details here)
- `/etc/cron.daily/adguard-dns-sync` (runs daily at ~6:25 AM)
- `/var/log/adguard-dns-sync.log` (logs everything)

## Usage

```bash
./adguard-dns-sync.sh [-H host] [-P port] -u user -p 'pass' [-D domain] [-d] [-v]

  -H host     AdGuard IP/hostname (default: adguard)
  -P port     AdGuard port (default: 3000)
  -u user     AdGuard username
  -p 'pass'   AdGuard password (quotes required for special chars)
  -D domain   DNS suffix (default: none). "plex" → "plex.local"
  -d          Dry-run (preview only)
  -v          Verbose debugging
```

**Examples:**

```bash
# No suffix (default) - "plex" → "plex"
./adguard-dns-sync.sh -H adguard -P 3000 -u USERNAME -p 'PASSWORD' -d

# With .local suffix
./adguard-dns-sync.sh -H adguard -P 3000 -u USERNAME -p 'PASSWORD' -D local -d

# Verbose dry-run
./adguard-dns-sync.sh -H adguard -P 3000 -u USERNAME -p 'PASSWORD' -d -v
```

## Configuration

Edit `/etc/adguard-dns-sync.conf`:

```bash
# AdGuard DNS Sync Configuration
# Permissions: 600 (root only)

ADGUARD_HOST="adguard"     # AdGuard IP/hostname
ADGUARD_PORT="3000"        # AdGuard HTTP port
ADGUARD_USER="USERNAME"    # API username
ADGUARD_PASS='PASSWORD'    # API password (quotes for special chars)
DNS_DOMAIN=""              # "" = no suffix, "local" = .local suffix
```

## Logs

All output goes to `/var/log/adguard-dns-sync.log`:

```bash
# View last runs
tail -50 /var/log/adguard-dns-sync.log

# Today's runs only
grep "$(date +%Y-%m-%d)" /var/log/adguard-dns-sync.log

# Follow live
tail -f /var/log/adguard-dns-sync.log
```

## How it works

1. **Queries Proxmox** (`pvesh get /cluster/resources --type vm`)
2. **Filters running** LXC/QEMU containers/VMs
3. **Gets IP addresses** (`pct exec VMID hostname -I` for LXC)
4. **Fetches existing** AdGuard rewrites
5. **PHASE 1: ADD/UPDATE** - creates/updates entries matching containers
6. **PHASE 2: DELETE** - identifies orphaned rewrites (in AdGuard but not in Proxmox)
   - Prompts once per record for approval
   - Only deletes if you answer `y` or `yes`
7. **Reports statistics** - shows final counts (Added/Updated/Deleted/Skipped)

## Available Implementations

Both versions have **identical behavior and features**:

| | Bash | Go |
| --- | ------ | ----- |
| **File** | `adguard-dns-sync.sh` | `adguard-dns-sync` (binary) |
| **Runtime** | Needs bash, jq, curl | Standalone binary (no deps) |
| **Speed** | Good | Faster (native binary) |
| **Size** | ~4 KB | ~8 MB |
| **Editing** | Easy to modify | Rebuild required |

**Use bash** if you want readable code and easy customization.
**Use Go** if you want a single portable binary (cross-compile friendly).

See [GOLANG.md](GOLANG.md) for Go-specific build instructions.

## Deletion Workflow

When rewrites exist in AdGuard but not in your Proxmox containers:

```log
[2026-02-26 14:35:22] [INFO] Found 2 AdGuard rewrite(s) not present in Proxmox list
Delete old-db.local -> 192.168.1.50? [y/N] y
[2026-02-26 14:35:23] [INFO] deleted old-db.local -> 192.168.1.50
Delete stale-app.local -> 192.168.1.60? [y/N] n
[2026-02-26 14:35:24] [INFO] skipped stale-app.local -> 192.168.1.60
```

Each record gets a prompt—**no automatic deletions**. Safe for cron!

## Log Format

All logs include ISO timestamps for easy parsing and audit trails:

```log
[2026-02-26 14:32:15] [INFO] Message
[2026-02-26 14:32:15] [DBG ] Debug message (only with -v)
[2026-02-26 14:32:15] [ERR ] Error message
```

## Troubleshooting

| Issue | Check |
| :-- | :-- |
| `pvesh not found` | Run on Proxmox host |
| `Cannot reach AdGuard` | Test: `curl -u user:pass http://host:port/control/status` |
| `No containers found` | Check: `pct list` / `qm list` |
| Script exits early | Add `-v` for debug output |
| Password with `!` | Use single quotes: `-p 'pass!'` |

**Questions?** Check the log file or add `-v` for debug output.

## Automation Options

| Method | Schedule | Command |
| :-- | :-- | :-- |
| **cron.daily** | ~6:25 AM daily | `sudo ./adguard-dns-setup.sh` |
| **Custom cron** | Every 10 min | `sudo crontab -e` |
| **Systemd timer** | Every 10 min | Service + timer files |

## Security

- **Config file:** `/etc/adguard-dns-sync.conf` (`chmod 600 root:root`)
- **Cron runs as root** (standard for system scripts)
- **Safe deletions** - each orphaned rewrite requires individual approval
- **Audit trail** - timestamped logs of all operations
- **No automatic changes** - dry-run by default with `-d` flag
- **Idempotent** - safe to run repeatedly

## License

[MIT License](LICENSE) © [Mohamed SALHI], 2026

***
