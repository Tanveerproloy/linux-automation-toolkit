#!/bin/bash

set -euo pipefail

# configuration (override with flags or edit here)
SOURCE_DIR="${HOME}/linux-automation-toolkit"
BACKUP_DIR="${HOME}/linux-automation-toolkit/backups"
LOG_FILE="/var/log/backup.log"
KEEP_DAYS=7
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
HOSTNAME=$(hostname)
ARCHIVE_NAME="backup_${HOSTNAME}_{$TIMESTAMP}".tar.gz
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

# --- colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- logging helpers ---
log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE" 2>/dev/null || true; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; log "OK" "$1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; log "ERROR" "$1"; exit 1; }
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; log "INFO" "$1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; log "WARN" "$1"; }

# parse arguments

RESTORE_FILE=""
LIST_MODE=false
VERIFY_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in 
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --dest) BACKUP_DIR="$2"; ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"; shift 2 ;;
        --keep) KEEP_DAYS="$2"; shift 2 ;;
        --restore) RESTORE_FILE="$2"; shift 2 ;;
        --verify) VERIFY_FILE="$2"; shift 2 ;;
        --list) LIST_MODE=true; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage/,/^# ====/p' "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# pre-flight validation
preflight() {
    info "Running pre-flight checks..."

    # verify source exists
    if [[ ! -d "$SOURCE_DIR" ]]; then
        error "Source directory does not exist: $SOURCE_DIR"
    fi

    # verify source is not empty
    local file_count
    file_count=$(find "$SOURCE_DIR" -type f | wc -l)
    if [[ "$file_count" -eq 0 ]]; then
        error "Source directory is empty: $SOURCE_DIR"
    fi

    # create backup destination if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # check available disk space
    local available_kb source_size_kb
    available_kb=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    source_size_kb=$(du -sk "$SOURCE_DIR" | awk '{print $1}')

    info "Source size:      $(du -sh "$SOURCE_DIR" | awk '{print $1}')"
    info "Available space:  $(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')"

    # compressed archive is roughly 40-70% of source for text files
    # use 80% of source size as a conservative estimate
    local estimated_size_kb
    estimated_size_kb=$(( source_size_kb * 80 / 100 ))

    if [[ "$available_kb" -lt "$estimated_size_kb" ]]; then
        error "Insufficient disk space. Need ~${estimated_size_kb}KB, have ${available_kb}KB"
    fi

    success "Pre-flight checks passed ($file_count files to back up)"
}

# create the backup archive
create_backup() {
    info "Starting backup of: $SOURCE_DIR"
    info "Destination: $ARCHIVE_PATH"
    echo ""

    # build the tar exclusion list
    local excludes=(
        "--exclude=${BACKUP_DIR}"          # never back up the backups themselves
        "--exclude=*.log"                  # skip log files (they change constantly)
        "--exclude=.git"                   # skip git history (recoverable from GitHub)
        "--exclude=__pycache__"            # skip Python cache
        "--exclude=node_modules"           # skip Node.js packages (use package.json)
        "--exclude=*.tmp"                  # skip temp files
        "--exclude=*.swp"                  # skip vim swap files
    )

    # create the archive with a progress indicator
    info "Creating archive..."

    if tar "${excludes[@]}" \
           --checkpoint=100 \
           --checkpoint-action=dot \
           -czf "$ARCHIVE_PATH" \
           "$SOURCE_DIR" 2>/dev/null; then
        echo ""  # newline after the progress dots
        success "Archive created: $ARCHIVE_NAME"
    else
        error "Archive creation failed"
    fi

    # record file size
    local size
    size=$(du -sh "$ARCHIVE_PATH" | awk '{print $1}')
    info "Archive size: $size"
}

# verify the archive is not corrupted
verify_backup() {
    local archive="${1:-$ARCHIVE_PATH}"

    info "Verifying archive integrity: $(basename "$archive")"

    # test the archive — tar reads through the entire compressed stream
    # and reports any corruption
    if tar -tzf "$archive" > /dev/null 2>&1; then
        local file_count
        file_count=$(tar -tzf "$archive" | wc -l)
        success "Archive verified — $file_count entries, no corruption detected"
        return 0
    else
        error "Archive verification FAILED — archive may be corrupted: $archive"
        return 1
    fi
}

# rotate old backups
rotate_backups() {
    info "Rotating old backups (keeping last ${KEEP_DAYS} days)..."

    # find and list what will be deleted BEFORE deleting
    local old_backups
    old_backups=$(find "$BACKUP_DIR" \
        -name "backup_*.tar.gz" \
        -mtime +"$KEEP_DAYS" \
        -type f)

    if [[ -z "$old_backups" ]]; then
        info "No backups older than $KEEP_DAYS days found — nothing to rotate"
        return 0
    fi

    # show what will be deleted
    local count
    count=$(echo "$old_backups" | grep -c .)
    warn "Found $count backup(s) older than $KEEP_DAYS days to remove:"
    echo "$old_backups" | while IFS= read -r old_file; do
        local size
        size=$(du -sh "$old_file" | awk '{print $1}')
        warn "  Removing: $(basename "$old_file") ($size)"
        rm -f "$old_file"
        log "ROTATED" "$(basename "$old_file")"
    done

    success "Rotation complete — $count old backup(s) removed"
}

# --- list all available backups ---
list_backups() {
    info "Available backups in: $BACKUP_DIR"
    echo ""

    local backups
    backups=$(find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f | sort -r)

    if [[ -z "$backups" ]]; then
        warn "No backups found in $BACKUP_DIR"
        return
    fi

    printf "  %-45s %-8s %-20s\n" "FILENAME" "SIZE" "DATE"
    printf "  %-45s %-8s %-20s\n" "--------" "----" "----"

    echo "$backups" | while IFS= read -r backup; do
        local size age
        size=$(du -sh "$backup" | awk '{print $1}')
        age=$(date -r "$backup" '+%Y-%m-%d %H:%M:%S')
        printf "  %-45s %-8s %-20s\n" "$(basename "$backup")" "$size" "$age"
    done

    echo ""
    local total_size
    total_size=$(du -sh "$BACKUP_DIR" | awk '{print $1}')
    info "Total backup storage used: $total_size"
}

# restore from a specific backup
restore_backup() {
    local archive="$1"

    # handle relative path — look in BACKUP_DIR if not a full path
    if [[ ! -f "$archive" ]]; then
        archive="${BACKUP_DIR}/${archive}"
    fi

    if [[ ! -f "$archive" ]]; then
        error "Backup file not found: $archive"
    fi

    echo -e "${BOLD}Restore from: $(basename "$archive")${NC}"
    echo ""

    # show what is inside before restoring
    info "Contents of archive (first 20 entries):"
    tar -tzf "$archive" | head -20
    echo ""

    # always verify before restoring
    verify_backup "$archive" || error "Refusing to restore from corrupted archive"

    # confirm with user
    echo -e "${YELLOW}WARNING: This will restore files to their original paths.${NC}"
    echo -e "${YELLOW}Existing files at those paths will be overwritten.${NC}"
    echo ""
    read -r -p "Proceed with restore? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { info "Restore cancelled."; exit 0; }

    info "Restoring..."
    tar -xzf "$archive" -C /
    success "Restore complete from: $(basename "$archive")"
    log "RESTORE" "Restored from $(basename "$archive")"
}

# --- print a final summary report ---
print_summary() {
    local start_time="$1"
    local end_time
    end_time=$(date '+%s')
    local duration=$(( end_time - start_time ))

    echo ""
    echo "================================================================="
    echo "  BACKUP SUMMARY"
    echo "================================================================="
    printf "  %-25s %s\n" "Archive:"     "$ARCHIVE_NAME"
    printf "  %-25s %s\n" "Source:"      "$SOURCE_DIR"
    printf "  %-25s %s\n" "Destination:" "$BACKUP_DIR"
    printf "  %-25s %s\n" "Duration:"    "${duration}s"
    printf "  %-25s %s\n" "Retention:"   "${KEEP_DAYS} days"
    printf "  %-25s %s\n" "Log:"         "$LOG_FILE"

    local backup_count
    backup_count=$(find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f | wc -l)
    printf "  %-25s %s\n" "Total backups on disk:" "$backup_count"

    local total_size
    total_size=$(du -sh "$BACKUP_DIR" | awk '{print $1}')
    printf "  %-25s %s\n" "Total backup storage:" "$total_size"
    echo "================================================================="
}

# setup 
setup() {
    sudo touch "$LOG_FILE" 2>/dev/null || true
    sudo chmod 666 "$LOG_FILE" 2>/dev/null || true
    mkdir -p "$BACKUP_DIR"
}

# main 
main() {
    setup

    # handle special modes first
    if [[ "$LIST_MODE" == true ]]; then
        list_backups
        exit 0
    fi

    if [[ -n "$VERIFY_FILE" ]]; then
        verify_backup "$VERIFY_FILE"
        exit 0
    fi

    if [[ -n "$RESTORE_FILE" ]]; then
        restore_backup "$RESTORE_FILE"
        exit 0
    fi

    # standard backup flow
    local start_time
    start_time=$(date '+%s')

    echo ""
    echo -e "${BOLD}Backup started: $(date)${NC}"
    echo ""

    log "START" "Backup of $SOURCE_DIR"

    preflight
    echo ""
    create_backup
    echo ""
    verify_backup
    echo ""
    rotate_backups
    echo ""
    print_summary "$start_time"

    log "COMPLETE" "Backup $ARCHIVE_NAME created and verified"
}

main "$@"