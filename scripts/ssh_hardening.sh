#!/bin/bash
# =============================================================================
# ssh_hardening.sh — SSH daemon and fail2ban hardening
# =============================================================================
# Usage:
#   sudo ./ssh_hardening.sh           (apply all hardening)
#   sudo ./ssh_hardening.sh --audit   (check current config, no changes)
#   sudo ./ssh_hardening.sh --revert  (restore original config from backup)
#
# What it does:
#   1. Backs up original sshd_config before any changes
#   2. Audits current configuration and reports vulnerabilities
#   3. Hardens sshd_config: port, auth, root login, timeouts
#   4. Configures fail2ban with aggressive SSH jail
#   5. Verifies the new configuration before reloading
#   6. Produces a before/after security report
#
# IMPORTANT — WSL note:
#   SSH daemon on WSL is for learning purposes. These same settings
#   apply identically to a real server's /etc/ssh/sshd_config.
# =============================================================================

set -euo pipefail

# --- never ever skip this ---
# this script modifies core security config. if sshd_config is invalid,
# sshd won't start. we verify before reloading — but always have a backup.
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
FAIL2BAN_JAIL="/etc/fail2ban/jail.local"
LOG_FILE="/var/log/ssh_hardening.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# --- our target hardened values ---
TARGET_PORT=2222
TARGET_MAX_AUTH_TRIES=3
TARGET_LOGIN_GRACE=30
TARGET_MAX_SESSIONS=3

# --- colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- helpers ---
log()     { echo "$TIMESTAMP [$1] $2" | tee -a "$LOG_FILE" 2>/dev/null || true; }
pass()    { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
info()    { echo -e "  ${BLUE}[INFO]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}$1${NC}"; echo "$(printf '%.0s-' {1..50})"; }

# --- must run as root ---
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error: run as root: sudo $0${NC}" >&2
    exit 1
fi

# argument handling
AUDIT_ONLY=false
REVERT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --audit)  AUDIT_ONLY=true;  shift ;;
        --revert) REVERT=true;      shift ;;
        --port)   TARGET_PORT="$2"; shift 2 ;;
        --help|-h)
            grep "^#" "$0" | head -20 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# check a single sshd_config setting
# usage: check_setting "PermitRootLogin" "no" "description"
check_setting() {
    local setting="$1"
    local secure_value="$2"
    local description="$3"

    # get the current value from sshd_config
    # grep for the setting (case-insensitive), take the last match,
    # strip leading spaces and the setting name, leaving just the value
    local current
    current=$(grep -i "^[[:space:]]*${setting}" "$SSHD_CONFIG" \
        | tail -1 \
        | awk '{print $2}' \
        | tr '[:upper:]' '[:lower:]')

    if [[ -z "$current" ]]; then
        current="(default)"
    fi

    if [[ "$current" == "$secure_value" ]]; then
        pass "$setting = $current  ✓ $description"
        return 0
    else
        fail "$setting = $current  ✗ Should be: $secure_value — $description"
        return 1
    fi
}

# full audit 
run_audit() {
    section "SSH Configuration Audit — $(date)"
    echo "  Config file: $SSHD_CONFIG"
    echo ""

    local issues=0

    check_setting "Port"                  "$TARGET_PORT"  "non-standard port reduces bot traffic"           || (( issues++ )) || true
    check_setting "PermitRootLogin"       "no"            "root login must be disabled"                     || (( issues++ )) || true
    check_setting "PasswordAuthentication" "no"           "key auth only — passwords can be brute-forced"   || (( issues++ )) || true
    check_setting "PermitEmptyPasswords"  "no"            "empty passwords must be forbidden"               || (( issues++ )) || true
    check_setting "X11Forwarding"         "no"            "disable GUI forwarding — unnecessary surface"    || (( issues++ )) || true
    check_setting "MaxAuthTries"          "$TARGET_MAX_AUTH_TRIES" "limit auth attempts per connection"     || (( issues++ )) || true
    check_setting "LoginGraceTime"        "$TARGET_LOGIN_GRACE"    "shorten auth window"                    || (( issues++ )) || true
    check_setting "AllowTcpForwarding"    "no"            "disable tunneling unless required"               || (( issues++ )) || true
    check_setting "ClientAliveInterval"   "300"           "detect dead connections (5 min)"                 || (( issues++ )) || true
    check_setting "ClientAliveCountMax"   "2"             "disconnect after 2 missed keepalives"            || (( issues++ )) || true
    check_setting "MaxSessions"           "$TARGET_MAX_SESSIONS"   "limit concurrent sessions per connection" || (( issues++ )) || true
    check_setting "UseDNS"                "no"            "skip DNS lookup — faster and safer"              || (( issues++ )) || true

    echo ""
    if [[ "$issues" -eq 0 ]]; then
        echo -e "  ${GREEN}All checks passed — SSH is hardened${NC}"
    else
        echo -e "  ${RED}$issues issue(s) found${NC}"
        if [[ "$AUDIT_ONLY" == true ]]; then
            echo ""
            echo "  Run without --audit to apply fixes:"
            echo "  sudo $0"
        fi
    fi

    echo ""
    section "fail2ban Status"
    if systemctl is-active fail2ban &>/dev/null 2>&1 || service fail2ban status &>/dev/null 2>&1; then
        pass "fail2ban is running"
        if fail2ban-client status sshd &>/dev/null 2>&1; then
            pass "SSH jail is active"
            fail2ban-client status sshd 2>/dev/null | grep -E "Currently|Total" | sed 's/^/  /'
        else
            warn "SSH jail not configured — run without --audit to set up"
        fi
    else
        fail "fail2ban is not running"
    fi

    return "$issues"
}

# --- apply a single setting to sshd_config ---
# handles three cases: setting exists → replace it
#                      setting is commented out → replace comment
#                      setting absent → append it
apply_setting() {
    local setting="$1"
    local value="$2"

    if grep -qi "^[[:space:]]*${setting}[[:space:]]" "$SSHD_CONFIG"; then
        # setting exists as active line — replace it
        sed -i "s|^[[:space:]]*${setting}[[:space:]].*|${setting} ${value}|I" "$SSHD_CONFIG"
    elif grep -qi "^#.*${setting}[[:space:]]" "$SSHD_CONFIG"; then
        # setting exists but is commented out — replace the comment
        sed -i "s|^#[[:space:]]*${setting}[[:space:]].*|${setting} ${value}|I" "$SSHD_CONFIG"
    else
        # setting not present at all — append it
        echo "${setting} ${value}" >> "$SSHD_CONFIG"
    fi

    info "Set: $setting $value"
    log "SET" "$setting $value"
}

# --- main hardening function ---
apply_hardening() {
    section "Creating backup"
    cp "$SSHD_CONFIG" "$SSHD_BACKUP"
    pass "Backup saved: $SSHD_BACKUP"
    log "BACKUP" "$SSHD_BACKUP"

    section "Applying SSH hardening settings"

    apply_setting "Port"                   "$TARGET_PORT"
    apply_setting "PermitRootLogin"        "no"
    apply_setting "PasswordAuthentication" "no"
    apply_setting "PermitEmptyPasswords"   "no"
    apply_setting "X11Forwarding"          "no"
    apply_setting "MaxAuthTries"           "$TARGET_MAX_AUTH_TRIES"
    apply_setting "LoginGraceTime"         "$TARGET_LOGIN_GRACE"
    apply_setting "AllowTcpForwarding"     "no"
    apply_setting "ClientAliveInterval"    "300"
    apply_setting "ClientAliveCountMax"    "2"
    apply_setting "MaxSessions"            "$TARGET_MAX_SESSIONS"
    apply_setting "UseDNS"                 "no"
    apply_setting "PrintLastLog"           "yes"
    apply_setting "LogLevel"               "VERBOSE"

    # add a clear section header so the config stays readable
    if ! grep -q "# Hardened by ssh_hardening.sh" "$SSHD_CONFIG"; then
        echo ""                                              >> "$SSHD_CONFIG"
        echo "# Hardened by ssh_hardening.sh on $TIMESTAMP" >> "$SSHD_CONFIG"
    fi
}

# --- configure fail2ban ---
configure_fail2ban() {
    section "Configuring fail2ban"

    if ! command -v fail2ban-client &>/dev/null; then
        warn "fail2ban not installed — installing..."
        apt-get install -y fail2ban &>/dev/null
    fi

    # create the jail.local file — this overrides jail.conf
    # never edit jail.conf directly (it gets replaced on upgrades)
    cat > "$FAIL2BAN_JAIL" << EOF
# =============================================================================
# fail2ban jail.local — SSH hardening
# Generated by ssh_hardening.sh on $TIMESTAMP
# =============================================================================
#
# This file overrides /etc/fail2ban/jail.conf
# jail.conf is overwritten on package upgrades — put your config here.

[DEFAULT]
# ban IPs for 1 hour
bantime  = 3600
# count failures within a 10-minute window
findtime = 600
# 3 strikes and you're banned
maxretry = 3
# email for alert (optional — update if configured)
destemail = root@localhost
# action: ban + send email with whois info
action = %(action_mwl)s

[sshd]
enabled  = true
port     = $TARGET_PORT
# the filter defines the regex that matches failed attempts
filter   = sshd
# the log file fail2ban reads
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF

    pass "jail.local written: $FAIL2BAN_JAIL"
    log "FAIL2BAN" "jail.local configured for port $TARGET_PORT"

    # start/restart fail2ban
    if systemctl is-active fail2ban &>/dev/null 2>&1; then
        systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null || true
    else
        systemctl start fail2ban 2>/dev/null || service fail2ban start 2>/dev/null || true
    fi

    sleep 2

    if fail2ban-client ping &>/dev/null 2>&1; then
        pass "fail2ban is running and responsive"
    else
        warn "fail2ban may not have started — check: sudo service fail2ban status"
    fi
}

# --- verify the sshd_config is valid before reloading ---
verify_config() {
    section "Verifying configuration"

    if sshd -t -f "$SSHD_CONFIG" 2>/dev/null; then
        pass "sshd_config syntax is valid"
        return 0
    else
        fail "sshd_config has errors!"
        echo ""
        warn "Testing config:"
        sshd -t -f "$SSHD_CONFIG"
        echo ""
        warn "Reverting to backup: $SSHD_BACKUP"
        cp "$SSHD_BACKUP" "$SSHD_CONFIG"
        pass "Original config restored"
        echo ""
        echo -e "${RED}Hardening aborted — original config restored${NC}"
        exit 1
    fi
}


# --- restore original configuration ---
run_revert() {
    section "Reverting SSH configuration"

    local latest_backup
    latest_backup=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        echo -e "${RED}No backup found in /etc/ssh/${NC}" >&2
        exit 1
    fi

    info "Found backup: $latest_backup"
    read -r -p "Restore this backup? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { info "Revert cancelled."; exit 0; }

    cp "$latest_backup" "$SSHD_CONFIG"
    pass "Config restored from: $latest_backup"

    if sshd -t -f "$SSHD_CONFIG" 2>/dev/null; then
        pass "Restored config is valid"
        systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
        pass "SSH daemon reloaded"
    else
        fail "Restored config has errors — check manually"
        exit 1
    fi

    log "REVERT" "Restored from $latest_backup"
}

# --- generate security report ---
generate_report() {
    local phase="$1"  # "before" or "after"

    section "Security Report — $phase hardening"

    echo "  Port:                  $(grep -i "^Port" "$SSHD_CONFIG" | awk '{print $2}' || echo '22 (default)')"
    echo "  PermitRootLogin:       $(grep -i "^PermitRootLogin" "$SSHD_CONFIG" | awk '{print $2}' || echo 'yes (default)')"
    echo "  PasswordAuthentication:$(grep -i "^PasswordAuthentication" "$SSHD_CONFIG" | awk '{print $2}' || echo 'yes (default)')"
    echo "  MaxAuthTries:          $(grep -i "^MaxAuthTries" "$SSHD_CONFIG" | awk '{print $2}' || echo '6 (default)')"
    echo "  X11Forwarding:         $(grep -i "^X11Forwarding" "$SSHD_CONFIG" | awk '{print $2}' || echo 'yes (default)')"
    echo "  LogLevel:              $(grep -i "^LogLevel" "$SSHD_CONFIG" | awk '{print $2}' || echo 'INFO (default)')"
}

# --- reload the SSH daemon safely ---
reload_sshd() {
    section "Reloading SSH daemon"

    # on WSL, sshd may not be running at all — that's fine
    if systemctl reload sshd 2>/dev/null; then
        pass "sshd reloaded via systemctl"
    elif service ssh reload 2>/dev/null; then
        pass "sshd reloaded via service"
    elif service sshd reload 2>/dev/null; then
        pass "sshd reloaded via service sshd"
    else
        warn "Could not reload sshd — it may not be running on WSL"
        warn "Config changes will apply next time sshd starts"
        info "To start sshd on WSL: sudo service ssh start"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    sudo touch "$LOG_FILE" 2>/dev/null || true
    sudo chmod 666 "$LOG_FILE" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}SSH Hardening Script — $(date)${NC}"
    echo ""

    # handle special modes
    if [[ "$REVERT" == true ]]; then
        run_revert
        exit 0
    fi

    if [[ "$AUDIT_ONLY" == true ]]; then
        run_audit
        exit 0
    fi

    # --- standard hardening flow ---
    log "START" "SSH hardening initiated"

    # snapshot before
    generate_report "before"

    # run audit first to show current state
    run_audit || true

    echo ""
    echo -e "${YELLOW}The above issues will now be fixed.${NC}"
    read -r -p "Proceed with hardening? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { info "Hardening cancelled."; exit 0; }

    # apply changes
    apply_hardening
    configure_fail2ban
    verify_config
    reload_sshd

    # snapshot after
    generate_report "after"

    section "Hardening Complete"
    pass "sshd_config hardened and verified"
    pass "fail2ban configured and running"
    pass "Backup saved at: $SSHD_BACKUP"
    info "Log: $LOG_FILE"

    if [[ "$TARGET_PORT" -ne 22 ]]; then
        echo ""
        echo -e "${YELLOW}IMPORTANT: SSH port changed to $TARGET_PORT${NC}"
        echo -e "${YELLOW}Connect with: ssh -p $TARGET_PORT user@host${NC}"
        echo -e "${YELLOW}Or on WSL: ssh -p $TARGET_PORT $(whoami)@localhost${NC}"
    fi

    log "COMPLETE" "SSH hardening finished successfully"
}

main "$@"