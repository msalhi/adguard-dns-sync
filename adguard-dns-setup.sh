#!/bin/bash
# AdGuard DNS Sync
# Copyright (c) 2026 [Mohamed SALHI]
# Licensed under MIT License - see LICENSE file for details
set -euo pipefail

SYNC_DIR="/root/adguard-dns-sync"
SYNC_SCRIPT="${SYNC_DIR}/adguard-dns-sync.sh"
CONF_FILE="/etc/adguard-dns-sync.conf"
CRON_SCRIPT="/etc/cron.daily/adguard-dns-sync"
LOG_FILE="/var/log/adguard-dns-sync.log"

echo "=== AdGuard DNS Sync - Setup ==="

# 1) Ensure main script exists
if [ ! -x "$SYNC_SCRIPT" ]; then
  echo "ERROR: $SYNC_SCRIPT not found or not executable."
  echo "Place your adguard-dns-sync.sh in $SYNC_DIR and chmod +x it."
  exit 1
fi

# 2) Create config file (if not exists)
if [ ! -f "$CONF_FILE" ]; then
  echo "Creating $CONF_FILE ..."
  cat > "$CONF_FILE" <<EOF
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
cat > "$CRON_SCRIPT" <<EOF
#!/bin/bash
#
# AdGuard DNS Sync - Daily automated sync
#

LOG_FILE="$LOG_FILE"
CONFIG_FILE="$CONF_FILE"

# Create logfile if not exist
if [ ! -f "\$LOG_FILE" ]; then
  touch "\$LOG_FILE"
  chmod 644 "\$LOG_FILE"
else
  # clean it to not fill the disk
  > "\$LOG_FILE"
fi

# Load configuration
if [ -f "\$CONFIG_FILE" ]; then
  # shellcheck source=/etc/adguard-dns-sync.conf
  source "\$CONFIG_FILE"
else
  echo "ERROR: Config file \$CONFIG_FILE not found" >> "\$LOG_FILE"
  exit 1
fi

# Log with timestamp
echo "=== AdGuard DNS Sync - \$(date) ===" >> "\$LOG_FILE"

# Run the sync script
"$SYNC_SCRIPT" \\
  -H "\$ADGUARD_HOST" \\
  -P "\$ADGUARD_PORT" \\
  -u "\$ADGUARD_USER" \\
  -p "\$ADGUARD_PASS" \\
  \${DNS_DOMAIN:+-D "\$DNS_DOMAIN"} \\
  >> "\$LOG_FILE" 2>&1

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ]; then
  echo "Sync completed successfully" >> "\$LOG_FILE"
else
  echo "Sync failed with exit code \$EXIT_CODE" >> "\$LOG_FILE"
fi

echo "" >> "\$LOG_FILE"

exit \$EXIT_CODE
EOF

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
echo "- Log:      $LOG_FILE"
echo
echo "Next steps:"
echo "  1) Edit $CONF_FILE and set ADGUARD_PASS correctly."
echo "  2) Test manually: $CRON_SCRIPT"
echo "  3) Check log: tail -50 $LOG_FILE"
