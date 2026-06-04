#!/bin/bash
# =============================================================================
# disk_monitor.sh — Disk usage monitor with multi-tier alerting
# =============================================================================
# Usage:
#   ./disk_monitor.sh              (uses default 80% threshold)
#   ./disk_monitor.sh --threshold 70
#   ./disk_monitor.sh --test       (simulates a full disk for testing)
#
# Alerting:
#   70%+  → logged only
#   80%+  → log + alert report file
#   90%+  → log + alert + wall broadcast to all terminals
# =============================================================================

set -euo pipefail

# --- configurable thresholds ---
WARN_THRESHOLD=80
CRIT_THRESHOLD=90
INFO_THRESHOLD=70

# --- paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/disk_monitor.log"
ALERT_FILE="$PROJECT_DIR/reports/disk_alerts.txt"
ENV_FILE="$PROJECT_DIR/.env"

# --- timestamp ---
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

# --- colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- helpers ---
log()  { echo "$TIMESTAMP $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "$TIMESTAMP $1"; }
info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
crit() { echo -e "${RED}[CRIT]${NC}  $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }

# --- parse arguments ---
TEST_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold)
            WARN_THRESHOLD="$2"
            shift 2
            ;;
        --test)
            TEST_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--threshold N] [--test]"
            echo "  --threshold N   Set warning threshold (default: 80)"
            echo "  --test          Simulate a full disk for testing"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- email/alert function ---
send_alert() {
    local subject="$1"
    local body="$2"
    local level="$3"   # INFO, WARN, CRIT

    # write to alert report file always
    {
        echo "=================================================="
        echo "ALERT [$level] — $TIMESTAMP"
        echo "Host: $HOSTNAME"
        echo "Subject: $subject"
        echo ""
        echo "$body"
        echo ""
    } >> "$ALERT_FILE"

    # attempt email if .env configures it
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        if [[ -n "${ALERT_EMAIL:-}" ]] && command -v mail &>/dev/null; then
            echo "$body" | mail -s "[$HOSTNAME] $subject" "$ALERT_EMAIL" 2>/dev/null \
                && log "EMAIL sent to $ALERT_EMAIL" \
                || log "EMAIL failed — check mail config"
        fi
    fi

    # for critical alerts, broadcast to all terminals
    if [[ "$level" == "CRIT" ]] && command -v wall &>/dev/null; then
        echo "DISK CRITICAL: $subject" | wall 2>/dev/null || true
    fi
}

# --- check a single filesystem ---
check_filesystem() {
    local usage="$1"
    local mount="$2"
    local filesystem="$3"

    # skip pseudo-filesystems we don't care about
    case "$mount" in
        /proc|/sys|/dev|/run/user*|/snap*)
            return 0
            ;;
    esac

    if [[ "$usage" -ge "$CRIT_THRESHOLD" ]]; then
        local msg="CRITICAL: $filesystem mounted at $mount is ${usage}% full"
        crit "$msg"
        log "CRITICAL $mount ${usage}%"
        send_alert "Disk CRITICAL: $mount at ${usage}%" \
"Filesystem:  $filesystem
Mount point: $mount
Usage:       ${usage}%
Threshold:   ${CRIT_THRESHOLD}%
Time:        $TIMESTAMP
Host:        $HOSTNAME

ACTION REQUIRED: Disk is nearly full. Free space immediately." \
            "CRIT"

    elif [[ "$usage" -ge "$WARN_THRESHOLD" ]]; then
        local msg="WARNING: $filesystem mounted at $mount is ${usage}% full"
        warn "$msg"
        log "WARNING $mount ${usage}%"
        send_alert "Disk Warning: $mount at ${usage}%" \
"Filesystem:  $filesystem
Mount point: $mount
Usage:       ${usage}%
Threshold:   ${WARN_THRESHOLD}%
Time:        $TIMESTAMP
Host:        $HOSTNAME

Please investigate and free up space." \
            "WARN"

    elif [[ "$usage" -ge "$INFO_THRESHOLD" ]]; then
        log "INFO $mount ${usage}% (approaching warning threshold)"
        info "$mount is at ${usage}% — watching"

    else
        ok "$mount is at ${usage}% — healthy"
    fi
}

# --- main disk check ---
run_checks() {
    info "Disk monitor starting — $(date)"
    info "Thresholds: info=${INFO_THRESHOLD}% warn=${WARN_THRESHOLD}% crit=${CRIT_THRESHOLD}%"
    echo ""

    local alert_count=0

    if [[ "$TEST_MODE" == true ]]; then
        info "TEST MODE: simulating a critical disk condition"
        check_filesystem 95 "/" "/dev/test"
        check_filesystem 85 "/home" "/dev/test2"
        check_filesystem 45 "/tmp" "/dev/test3"
        return
    fi

    # read df output line by line, skipping header (NR>1)
    while IFS= read -r line; do
        # extract fields using awk
        local usage filesystem mount
        usage=$(echo "$line"    | awk '{gsub(/%/,"",$5); print $5}')
        filesystem=$(echo "$line" | awk '{print $1}')
        mount=$(echo "$line"    | awk '{print $6}')

        # skip empty lines or lines without a valid percentage
        [[ -z "$usage" || ! "$usage" =~ ^[0-9]+$ ]] && continue

        check_filesystem "$usage" "$mount" "$filesystem"
        [[ "$usage" -ge "$WARN_THRESHOLD" ]] && (( alert_count++ )) || true

    done < <(df -h | awk 'NR>1')

    echo ""
    if [[ "$alert_count" -eq 0 ]]; then
        ok "All filesystems healthy. Check complete at $TIMESTAMP"
        log "CHECK_OK all filesystems below ${WARN_THRESHOLD}% threshold"
    else
        warn "$alert_count filesystem(s) need attention"
        log "CHECK_DONE $alert_count alerts generated"
        info "See alert report: $ALERT_FILE"
    fi
}

# --- ensure directories and files exist ---
setup() {
    sudo touch "$LOG_FILE" 2>/dev/null || true
    sudo chmod 666 "$LOG_FILE" 2>/dev/null || true
    mkdir -p "$(dirname "$ALERT_FILE")"
    touch "$ALERT_FILE"
}

# --- entry point ---
setup
run_checks