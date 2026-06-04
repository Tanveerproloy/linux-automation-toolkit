#!/bin/bash
#======================================================================================
# user_manager.sh - User account lifecycle management
#======================================================================================
# usage:
# sudo ./user_manager.sh create <username> 
# sudo ./user_manager.sh delete <username>
# sudo ./user_manager.sh list
# what it does:
# create - creates a new user, adds to group, forces password change
# delete - removes user and their home directory
# list - shows all non system accounts (UID >= 1000)
#=====================================================================================

set -eou pipefail

#visual output helpers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0;0m'

#logging
LOG_FILE="/var/log/user_manager.log"
TIMESTAMP=$(date '+%Y-%m-%d %H-%M-S')


#helper functions

log() { echo "$TIMESTAMP [$1] $2" | sudo tee -a "$LOG_FILE";}
success() { echo -e "${GREEN}[OK]${NC} $1"; log "OK" "$1";}
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; log "ERROR" "$1"; exit 1;}
info() { echo -e "${BLUE}[INFO]${NC} $1";log "INFO" "$1";}
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN" "$1";}


# ensure script runs as root

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
    fi
}


# usage instructions
usage() {
    echo ""
    echo "Usage: sudo $0 <action> [options]"
    echo ""
    echo "Actions:"
    echo "  create <username> [group]   Create user, add to group (default: sudo)"
    echo "  delete <username>           Delete user and home directory"
    echo "  list                        List all human users (UID >= 1000)"
    echo ""
    echo "Examples:"
    echo "  sudo $0 create alice developers"
    echo "  sudo $0 delete alice"
    echo "  sudo $0 list"
    echo ""
    exit 1
}

# Create user function

create_user() {
    local username="$1"
    local group="${2:-sudo}"   # default group is sudo if not specified

    # --- validate username format ---
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "Invalid username '$username'. Use lowercase letters, numbers, hyphens, underscores only."
    fi

    # --- check if user already exists ---
    if id "$username" &>/dev/null; then
        error "User '$username' already exists."
    fi

    # --- check if group exists, create if not ---
    if ! getent group "$group" &>/dev/null; then
        info "Group '$group' does not exist. Creating it..."
        groupadd "$group"
        success "Group '$group' created."
    fi

    info "Creating user '$username' in group '$group'..."

    # --- create the user ---
    useradd \
        --create-home \
        --shell /bin/bash \
        --gid "$group" \
        --comment "Created by user_manager.sh on $TIMESTAMP" \
        "$username"

    # --- set a temporary password ---
    local temp_password
    temp_password=$(openssl rand -base64 12)
    echo "$username:$temp_password" | chpasswd

    # --- force password change on first login ---
    chage --lastday 0 "$username"

    success "User '$username' created successfully."
    echo ""
    echo "  Temporary password: $temp_password"
    echo "  User must change password on first login."
    echo ""

    log "OK" "User '$username' created, added to group '$group'"
}

delete_user() {
    local username="$1"

    # --- verify user exists before trying to delete ---
    if ! id "$username" &>/dev/null; then
        error "User '$username' does not exist."
    fi

    # --- safety check: dont delete system accounts or root ---
    local uid
    uid=$(id -u "$username")
    if [[ "$uid" -lt 1000 ]]; then
        error "Refusing to delete system account '$username' (UID $uid < 1000)."
    fi

    warn "About to delete user '$username' and their home directory."
    read -r -p "Are you sure? (yes/no): " confirmation

    if [[ "$confirmation" != "yes" ]]; then
        info "Deletion cancelled."
        exit 0
    fi

    info "Deleting user '$username'..."

    # --- kill any running processes owned by this user ---
    pkill -u "$username" 2>/dev/null || true

    # --- delete user and home directory ---
    userdel --remove "$username"

    # --- verify deletion ---
    if id "$username" &>/dev/null; then
        error "Deletion failed — user '$username' still exists."
    fi

    success "User '$username' and home directory deleted."
}

list_users() {
    info "Human user accounts (UID >= 1000):"
    echo ""
    printf "%-20s %-8s %-20s %-30s\n" "USERNAME" "UID" "GROUP" "HOME"
    printf "%-20s %-8s %-20s %-30s\n" "--------" "---" "-----" "----"

    while IFS=: read -r username _ uid gid _ home shell; do
        if [[ "$uid" -ge 1000 && "$uid" -ne 65534 && "$shell" != "/usr/sbin/nologin" && "$shell" != "/bin/false" ]]; then
            local group_name
            group_name=$(getent group "$gid" | cut -d: -f1)
            printf "%-20s %-8s %-20s %-30s\n" "$username" "$uid" "$group_name" "$home"
        fi
    done < /etc/passwd
    echo ""
}


# MAIN Function

main() {
    check_root

    # --- require at least one argument ---
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local action="$1"
    shift   # remove $1 from argument list, so $2 becomes $1, etc.

    case "$action" in
        create)
            [[ $# -lt 1 ]] && error "Usage: $0 create <username> [group]"
            create_user "$@"
            ;;
        delete)
            [[ $# -ne 1 ]] && error "Usage: $0 delete <username>"
            delete_user "$1"
            ;;
        list)
            list_users
            ;;
        --help|-h)
            usage
            ;;
        *)
            error "Unknown action '$action'. Use create, delete, or list."
            ;;
    esac
}

# --- run main, passing all script arguments ---
main "$@"