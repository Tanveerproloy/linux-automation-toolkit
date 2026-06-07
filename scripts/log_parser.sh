#!/bin/bash
# =============================================================================
# log_parser.sh — SSH threat intelligence report from auth.log
# =============================================================================
# Usage:
#   sudo ./log_parser.sh                  (parse today's log)
#   sudo ./log_parser.sh --days 7         (parse last 7 days of logs)
#   sudo ./log_parser.sh --top 20         (show top 20 IPs, default 10)
#   sudo ./log_parser.sh --watch          (live mode, refresh every 30s)
# =============================================================================

set -euo pipefail

# --- configuration ---
LOG_FILE="/var/log/auth.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
REPORT_FILE="$REPORT_DIR/ssh_report_${TIMESTAMP}.txt"
HOSTNAME=$(hostname)

# --- defaults ---
TOP_COUNT=10
WATCH_MODE=false
DAYS=1

# --- colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            DAYS="$2"
            shift 2
            ;;
        --top)
            TOP_COUNT="$2"
            shift 2
            ;;
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --log)
            LOG_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: sudo $0 [--days N] [--top N] [--watch] [--log path]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- collect log content, handling rotation and compression ---
collect_logs() {
    local combined_log
    combined_log=$(mktemp)    # create a temporary file

    # always include the main log
    if [[ -f "$LOG_FILE" ]]; then
        sudo cat "$LOG_FILE" >> "$combined_log"
    fi

    # include rotated logs if --days > 1
    if [[ "$DAYS" -gt 1 ]]; then
        local i
        for (( i=1; i<DAYS; i++ )); do
            # uncompressed rotated log
            if [[ -f "${LOG_FILE}.${i}" ]]; then
                sudo cat "${LOG_FILE}.${i}" >> "$combined_log"
            fi
            # compressed rotated log
            if [[ -f "${LOG_FILE}.${i}.gz" ]]; then
                sudo zcat "${LOG_FILE}.${i}.gz" >> "$combined_log"
            fi
        done
    fi

    echo "$combined_log"    # return the temp file path
}

# --- extract failed login attempts ---
get_failed_attempts() {
    local logfile="$1"
    # "Failed password for root from 1.2.3.4 port 1234 ssh2"
    # "Failed password for invalid user deploy from 1.2.3.4 port 1234"
    grep "Failed password" "$logfile" 2>/dev/null || true
}

# --- extract invalid user attempts ---
get_invalid_users() {
    local logfile="$1"
    # "Invalid user www-data from 1.2.3.4 port 1234"
    grep "Invalid user" "$logfile" 2>/dev/null || true
}

# --- extract successful logins ---
get_successful_logins() {
    local logfile="$1"
    grep "Accepted" "$logfile" 2>/dev/null || true
}

# --- extract attacker IPs from failed attempts ---
extract_ips_from_failures() {
    local logfile="$1"
    {
        # for "Failed password for <user> from <ip>"
        get_failed_attempts "$logfile" | awk '{print $11}'
        # for "Invalid user <user> from <ip>"
        get_invalid_users   "$logfile" | awk '{print $10}'
    } | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || true
}

# --- extract targeted usernames ---
extract_usernames() {
    local logfile="$1"
    {
        get_failed_attempts "$logfile" | awk '{
            # handle both "for root" and "for invalid user root"
            if ($9 == "invalid") print $10
            else print $9
        }'
        get_invalid_users "$logfile" | awk '{print $9}'
    } | grep -v "^$" || true
}

# --- generate the full report ---
generate_report() {
    local logfile="$1"
    local output="$2"   # file path or "-" for stdout

    # collect all the data first
    local failed_lines invalid_lines success_lines
    failed_lines=$(get_failed_attempts "$logfile")
    invalid_lines=$(get_invalid_users "$logfile")
    success_lines=$(get_successful_logins "$logfile")

    local failed_count invalid_count success_count unique_ips
    failed_count=$(echo "$failed_lines"  | grep -c . || echo 0)
    invalid_count=$(echo "$invalid_lines" | grep -c . || echo 0)
    success_count=$(echo "$success_lines" | grep -c . || echo 0)
    unique_ips=$(extract_ips_from_failures "$logfile" | sort -u | grep -c . || echo 0)

    # --- build the report ---
    {
    echo "================================================================="
    echo "  SSH THREAT INTELLIGENCE REPORT"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Host:      $HOSTNAME"
    echo "  Log file:  $LOG_FILE"
    echo "================================================================="
    echo ""

    echo "SUMMARY"
    echo "-------"
    printf "  %-35s %s\n" "Total failed attempts:"     "$failed_count"
    printf "  %-35s %s\n" "Total invalid usernames:"   "$invalid_count"
    printf "  %-35s %s\n" "Total unique attacker IPs:" "$unique_ips"
    printf "  %-35s %s\n" "Successful logins:"         "$success_count"
    echo ""

    echo "TOP ATTACKING IPs (by attempt count)"
    echo "--------------------------------------"
    printf "  %-10s %s\n" "Attempts" "IP Address"
    printf "  %-10s %s\n" "--------" "----------"
    extract_ips_from_failures "$logfile" \
        | sort | uniq -c | sort -rn \
        | head -"$TOP_COUNT" \
        | awk '{printf "  %-10s %s\n", $1, $2}'
    echo ""

    echo "MOST TARGETED USERNAMES"
    echo "------------------------"
    printf "  %-8s %s\n" "Count" "Username"
    printf "  %-8s %s\n" "-----" "--------"
    extract_usernames "$logfile" \
        | sort | uniq -c | sort -rn \
        | head -"$TOP_COUNT" \
        | awk '{printf "  %-8s %s\n", $1, $2}'
    echo ""

    echo "SUCCESSFUL LOGINS (verify these are legitimate)"
    echo "------------------------------------------------"
    if [[ -z "$success_lines" ]]; then
        echo "  None recorded in this period."
    else
        echo "$success_lines" \
            | awk '{printf "  %s %s %s  %-10s %s\n", $1,$2,$3,$9,$11}'
    fi
    echo ""

    echo "DETAILED ATTACK LOG (last 20 attempts)"
    echo "----------------------------------------"
    {
        echo "$failed_lines"
        echo "$invalid_lines"
    } | sort | tail -20 \
      | awk '{
          type = "FAIL"
          user = ($9 == "invalid") ? $11 : $9
          ip   = ($9 == "invalid") ? $13 : $11
          printf "  %s %s %s  %-6s %-15s %s\n", $1,$2,$3,type,user,ip
      }'
    echo ""

    echo "================================================================="
    printf "  Report saved: %s\n" "$REPORT_FILE"
    echo "================================================================="

    } | tee "$output"
}

# --- live watch mode ---
run_watch() {
    local logfile="$1"
    echo -e "${CYAN}Watch mode active — refreshing every 30 seconds. Ctrl+C to stop.${NC}"
    while true; do
        clear
        generate_report "$logfile" /dev/stdout
        echo ""
        echo -e "${YELLOW}Next refresh in 30 seconds... (Ctrl+C to stop)${NC}"
        sleep 30
    done
}

# --- setup ---
setup() {
    mkdir -p "$REPORT_DIR"
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${RED}Error: Log file not found: $LOG_FILE${NC}" >&2
        echo "On WSL, check: sudo ls /var/log/auth.log" >&2
        exit 1
    fi
}

# --- main ---
main() {
    setup

    local logfile
    logfile=$(collect_logs)

    # clean up temp file when script exits for any reason
    trap "rm -f '$logfile'" EXIT

    echo -e "${BOLD}SSH Log Parser — $(date)${NC}"
    echo ""

    if [[ "$WATCH_MODE" == true ]]; then
        run_watch "$logfile"
    else
        generate_report "$logfile" "$REPORT_FILE"
        echo ""
        echo -e "${GREEN}Report saved to: $REPORT_FILE${NC}"
    fi
}

main "$@"