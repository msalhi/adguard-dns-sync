#!/bin/bash
# AdGuard DNS Sync
# Copyright (c) 2026 [Mohamed SALHI]
# Licensed under MIT License - see LICENSE file for details
set -euo pipefail

# --- CONFIG ---
ADGUARD_HOST="${ADGUARD_HOST:-adguard}"
ADGUARD_PORT="${ADGUARD_PORT:-3000}"
ADGUARD_USER="${ADGUARD_USER:-username}"
ADGUARD_PASS="${ADGUARD_PASS:-password}"
DNS_DOMAIN="${DNS_DOMAIN:-}"
DRY_RUN=0
VERBOSE=0

log()  { echo "[INFO] $*"; }

# Fixed: return 0 to avoid exiting when set -e is active
dbg()  { [ "$VERBOSE" -eq 1 ] && echo "[DBG ] $*" || true; }

err()  { echo "[ERR ] $*" >&2; }

usage() {
  cat <<EOF
Usage: $0 [-H host] [-P port] -u user -p 'pass' [-D domain] [-d] [-v]

  -H  AdGuard host (default: $ADGUARD_HOST)
  -P  AdGuard port (default: $ADGUARD_PORT)
  -u  AdGuard username
  -p  AdGuard password (USE QUOTES if it has !, $, etc.)
  -D  DNS suffix (default: $DNS_DOMAIN, '' to disable)
  -d  Dry-run (show what would change, no writes)
  -v  Verbose

Example:
  $0 -H 192.168.1.109 -P 80 -u MyUser -p 'MyPass!' -D local -d -v
EOF
}

# --- args ---
while getopts "H:P:u:p:D:dvh" opt; do
  case "$opt" in
    H) ADGUARD_HOST="$OPTARG" ;;
    P) ADGUARD_PORT="$OPTARG" ;;
    u) ADGUARD_USER="$OPTARG" ;;
    p) ADGUARD_PASS="$OPTARG" ;;
    D) DNS_DOMAIN="$OPTARG" ;;
    d) DRY_RUN=1 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[ -z "$ADGUARD_USER" ] && err "Missing -u user" && usage && exit 1
[ -z "$ADGUARD_PASS" ] && err "Missing -p 'pass'" && usage && exit 1

BASE_URL="http://${ADGUARD_HOST}:${ADGUARD_PORT}"
AUTH="-u ${ADGUARD_USER}:${ADGUARD_PASS}"

# --- quick checks ---
if ! command -v pvesh >/dev/null 2>&1; then
  err "pvesh not found. Run this on the Proxmox host."
  exit 1
fi

if ! curl -s ${AUTH} "${BASE_URL}/control/status" >/dev/null 2>&1; then
  err "Cannot reach AdGuard at ${BASE_URL}/control/status"
  exit 1
fi

dbg "AdGuard OK at ${BASE_URL}"
log "Dry-run: $([ $DRY_RUN -eq 1 ] && echo yes || echo no)"

# --- fetch Proxmox VMs (LXC + QEMU) ---
dbg "Fetching running containers/VMs from Proxmox..."
VMS_JSON="$(pvesh get /cluster/resources --type vm --output-format json)"

# Filter: running + type lxc or qemu
VMS_JSON="$(echo "$VMS_JSON" | jq '[.[] | select(.status=="running") | select(.type=="lxc" or .type=="qemu")]')"

COUNT="$(echo "$VMS_JSON" | jq 'length')"
log "Found $COUNT running containers/VMs"

if [ "$COUNT" -eq 0 ]; then
  log "Nothing to do."
  exit 0
fi

# --- build desired DNS map: name -> ip ---
declare -A DESIRED

for row in $(echo "$VMS_JSON" | jq -r '.[] | @base64'); do
  _jq() { echo "$row" | base64 -d | jq -r "$1"; }
  VMID="$(_jq '.vmid')"
  NAME="$(_jq '.name')"
  TYPE="$(_jq '.type')"

  # get IP from inside container/VM
  if [ "$TYPE" = "lxc" ]; then
    IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  elif [ "$TYPE" = "qemu" ]; then
    IP="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
          jq -r '.result[].ip-addresses[]? | select(."ip-family"=="ipv4").address' | \
          grep -v "^127\." | head -1)"
  else
    IP=""
  fi

  if [ -z "$IP" ]; then
    dbg "Skipping ${NAME} (vmid ${VMID}, type ${TYPE}) - no IP"
    continue
  fi

  if [ -n "$DNS_DOMAIN" ]; then
    FQDN="${NAME}.${DNS_DOMAIN}"
  else
    FQDN="${NAME}"
  fi

  DESIRED["$FQDN"]="$IP"
  log "want: ${FQDN} -> ${IP}"
done

if [ "${#DESIRED[@]}" -eq 0 ]; then
  log "No containers/VMs with IPs found; nothing to sync."
  exit 0
fi

# --- fetch current AdGuard rewrites ---
RAW_REWRITES="$(curl -s ${AUTH} "${BASE_URL}/control/rewrite/list")"
[ "$RAW_REWRITES" = "null" ] && RAW_REWRITES="[]"

declare -A CURRENT
for row in $(echo "$RAW_REWRITES" | jq -r '.[] | @base64'); do
  _jq() { echo "$row" | base64 -d | jq -r "$1"; }
  D="$(_jq '.domain')"
  A="$(_jq '.answer')"
  CURRENT["$D"]="$A"
done

# --- sync: ADD and UPDATE only (NO DELETE) ---
for DOMAIN in "${!DESIRED[@]}"; do
  NEW_IP="${DESIRED[$DOMAIN]}"
  OLD_IP="${CURRENT[$DOMAIN]:-}"

  if [ -z "$OLD_IP" ]; then
    # add new entry
    if [ $DRY_RUN -eq 1 ]; then
      log "[DRY] add ${DOMAIN} -> ${NEW_IP}"
    else
      dbg "Adding ${DOMAIN} -> ${NEW_IP}"
      curl -s -X POST ${AUTH} \
        -H "Content-Type: application/json" \
        -d "{\"domain\":\"${DOMAIN}\",\"answer\":\"${NEW_IP}\"}" \
        "${BASE_URL}/control/rewrite/add" >/dev/null
      log "added ${DOMAIN} -> ${NEW_IP}"
    fi
  elif [ "$OLD_IP" != "$NEW_IP" ]; then
    # update existing entry (delete old + add new)
    if [ $DRY_RUN -eq 1 ]; then
      log "[DRY] update ${DOMAIN}: ${OLD_IP} -> ${NEW_IP}"
    else
      dbg "Updating ${DOMAIN}: ${OLD_IP} -> ${NEW_IP}"
      curl -s -X POST ${AUTH} \
        -H "Content-Type: application/json" \
        -d "{\"domain\":\"${DOMAIN}\",\"answer\":\"${OLD_IP}\"}" \
        "${BASE_URL}/control/rewrite/delete" >/dev/null

      curl -s -X POST ${AUTH} \
        -H "Content-Type: application/json" \
        -d "{\"domain\":\"${DOMAIN}\",\"answer\":\"${NEW_IP}\"}" \
        "${BASE_URL}/control/rewrite/add" >/dev/null

      log "updated ${DOMAIN}: ${OLD_IP} -> ${NEW_IP}"
    fi
  else
    dbg "unchanged ${DOMAIN} -> ${OLD_IP}"
  fi
done

log "Sync done. Manual DNS entries left untouched."

