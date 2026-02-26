#!/bin/bash
# AdGuard DNS Sync Setup
# Copyright (c) 2026 [Mohamed SALHI]
# Licensed under MIT License - see LICENSE file for details
set -euo pipefail

SYNC_DIR="/root/adguard-dns-sync"
SYNC_SCRIPT="${SYNC_DIR}/adguard-dns-sync.sh"
SYNC_BINARY="${SYNC_DIR}/adguard-dns-sync"
CONF_FILE="/etc/adguard-dns-sync.conf"
CRON_SCRIPT="/etc/cron.daily/adguard-dns-sync"
LOG_FILE="/var/log/adguard-dns-sync.log"

echo "=== AdGuard DNS Sync - Setup ==="
echo
echo "This tool supports both Bash and Go implementations."
echo "Choose which version to use:"
echo
echo "  [1] Bash version (adguard-dns-sync.sh) - easy to modify"
echo "  [2] Go version (adguard-dns-sync) - faster, portable binary"
echo

read -r -p "Select [1 or 2]: " CHOICE

case "$CHOICE" in
  1) SCRIPT_TO_USE="$SYNC_SCRIPT" ;;
  2) SCRIPT_TO_USE="$SYNC_BINARY" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

echo
echo "Using: $SCRIPT_TO_USE"
echo

# 1) Ensure main script exists
if [ ! -x "$SCRIPT_TO_USE" ]; then
  echo "ERROR: $SCRIPT_TO_USE not found or not executable."
  echo "Place the script/binary in $SYNC_DIR and chmod +x it."
  exit 1
fi

# 2) Create config file (if not exists)
if [ ! -f "$CONF_FILE" ]; then
  echo "Creating $CONF_FILE ..."
  cat > "$CONF_FILE" <<'EOF'
# AdGuard DNS Sync Configuration
# Only root should be able to read this file.
# Permissions will be set to 600.

ADGUARD_HOST="adguard"
ADGUARD_PORT="3000"
ADGUARD_USER="USERNAME"
ADGUARD_PASS='PASSWORD'
DNS_DOMAIN=""
EOF
else
  echo "$CONF_FILE already exists, leaving it as is."
fi

# Secure config file (root-only) [rw-------]
chmod 600 "$CONF_FILE"
chown root:root "$CONF_FILE"

# 3) Create cron.daily script
echo "Creating $CRON_SCRIPT ..."
cat > "$CRON_SCRIPT" <<'EOFCRON'
#!/bin/bash
#
# AdGuard DNS Sync - Daily automated sync
# Supports both Bash and Go implementations
#

LOG_FILE="/var/log/adguard-dns-sync.log"
CONFIG_FILE="/etc/adguard-dns-sync.conf"

# Create logfile if not exist
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
else
  # Rotate log (keep last run only)
  > "$LOG_FILE"
fi

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/etc/adguard-dns-sync.conf
  source "$CONFIG_FILE"
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERR ] Config file $CONFIG_FILE not found" >> "$LOG_FILE"
  exit 1
fi

# Run the sync script (with timestamps & error validation)
echo "===== AdGuard DNS Sync - $(date +'%Y-%m-%d %H:%M:%S') =====" >> "$LOG_FILE"

# Auto-detect which script is available
SCRIPT_PATH=""
if [ -x "/root/adguard-dns-sync/adguard-dns-sync.sh" ]; then
  SCRIPT_PATH="/root/adguard-dns-sync/adguard-dns-sync.sh"
elif [ -x "/root/adguard-dns-sync/adguard-dns-sync" ]; then
  SCRIPT_PATH="/root/adguard-dns-sync/adguard-dns-sync"
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERR ] No sync script found" >> "$LOG_FILE"
  exit 1
fi

"$SCRIPT_PATH" \
  -H "$ADGUARD_HOST" \
  -P "$ADGUARD_PORT" \
  -u "$ADGUARD_USER" \
  -p "$ADGUARD_PASS" \
  ${DNS_DOMAIN:+-D "$DNS_DOMAIN"} \
  >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] Sync completed successfully" >> "$LOG_FILE"
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERR ] Sync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"

exit $EXIT_CODE
EOFCRON

chmod 755 "$CRON_SCRIPT"
chown root:root "$CRON_SCRIPT"

# 4) Ensure log file exists
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
  chown root:root "$LOG_FILE"
fi

echo
echo "Setup complete."
echo "- Config:   $CONF_FILE (secured 600, edit password & options there)"
echo "- Cron job: $CRON_SCRIPT (runs daily via cron.daily)"
echo "- Log:      $LOG_FILE (includes timestamps for all operations)"
echo
echo "Features:"
echo "  ✓ Per-item deletion confirmation (safe for cron)"
echo "  ✓ ISO 8601 timestamps on all log entries"
echo "  ✓ Operation statistics (Added/Updated/Deleted/Skipped)"
echo "  ✓ HTTP error validation"
echo
echo "Next steps:"
echo "  1) Edit $CONF_FILE and set ADGUARD_PASS correctly."
echo "  2) Test manually: $CRON_SCRIPT"
echo "  3) Check log: tail -50 $LOG_FILE"
echo "  4) View statistics: tail -1 $LOG_FILE (last line shows counts)"
