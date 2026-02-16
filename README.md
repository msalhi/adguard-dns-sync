# AdGuard DNS Sync for Proxmox

**Syncs Proxmox containers/VMs to AdGuardHome DNS rewrites automatically.**

Scans LXCs/VMs hostnames and IPs to creates DNS entries like `plex → 192.168.1.100` automatically to AdGuardHome's DNS rewrites so you can access containers by name anywhere on your network.

## Features

- ✅ **Add/update only** - won't delete your manual DNS entries
- ✅ **LXC + QEMU** support
- ✅ **Idempotent** - safe to run repeatedly
- ✅ **Dry-run mode** (`-d`) - preview changes
- ✅ **Production-ready** - works with cron.daily/systemd
- ✅ **Lightweight** - ~100 lines, minimal dependencies
- ✅ **Secure** - root-only config file


## Requirements

- Proxmox host (script runs locally)
- AdGuard Home accessible via HTTP API
- `jq`, `curl`, `pct`, `qm` (standard on Proxmox)


## Quick Start

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

```
[INFO] Dry-run: yes
[INFO] Found 3 running containers/VMs
[INFO] want: plex -> 192.168.1.100
[INFO] want: jellyfin -> 192.168.1.101
[INFO] [DRY] add plex -> 192.168.1.100
[INFO] Sync done. Manual DNS entries left untouched.
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
5. **Adds/updates** only changed entries
6. **Leaves manual entries alone** ✅

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
- **No delete logic** - preserves manual entries
- **Idempotent** - safe to run repeatedly


## License

[MIT License](LICENSE) © [Mohamed SALHI], 2026

***

