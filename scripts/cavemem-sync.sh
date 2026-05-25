#!/bin/bash
# ==============================================================================
#   cachy-ai-tools - cavemem-sync.sh
#   Purpose: Securely sync cavemem SQLite memory database between LAN computers
# ==============================================================================
set -euo pipefail

# ANSI color codes
CYAN="\e[1;36m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
RESET="\e[0m"

log_info() { echo -e "${CYAN}[*] $1${RESET}"; }
log_success() { echo -e "${GREEN}[+] $1${RESET}"; }
log_warn() { echo -e "${YELLOW}[!] $1${RESET}"; }
log_error() { echo -e "${RED}[ERROR] $1${RESET}" >&2; }

find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" && "$dir" != "$HOME" ]]; do
        if [[ -d "$dir/.git" || -d "$dir/.cavemem" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    if [[ "$PWD" == "$HOME/workspace/"* ]]; then
        local subpath="${PWD#$HOME/workspace/}"
        local project_name="${subpath%%/*}"
        echo "$HOME/workspace/$project_name"
        return 0
    elif [[ "$PWD" == "$HOME/Github/"* ]]; then
        local subpath="${PWD#$HOME/Github/}"
        local project_name="${subpath%%/*}"
        echo "$HOME/Github/$project_name"
        return 0
    fi
    echo "$HOME"
}

PROJECT_ROOT=$(find_project_root)
CONFIG_FILE="$HOME/.cavemem/sync_config.json"

# v2 layout: cavemem-stack/dbs/<project>.db (one DB per project, all under repo dir).
# Auto-detect: if CAVEMEM_STACK_DIR is set or default exists, use the new layout.
# Otherwise fall back to legacy .cavemem/data.db so old setups keep working.
DEFAULT_STACK_DIR="$HOME/Github/cachy-ai-tools/cavemem-stack"
STACK_DIR="${CAVEMEM_STACK_DIR:-$DEFAULT_STACK_DIR}"

if [ -d "$STACK_DIR/dbs" ]; then
    # New stack layout: sync the entire dbs/ directory (all project DBs)
    log_info "v2 stack layout detected at $STACK_DIR"
    LOCAL_DIR="$STACK_DIR/dbs"
    LOCAL_DB="$LOCAL_DIR"             # treated as a directory for rsync
    REMOTE_DIR="$STACK_DIR/dbs"
    REMOTE_DB="$REMOTE_DIR"
    REMOTE_PROJECT_ROOT="$HOME"
    SYNC_MODE="dir"
elif [[ "$PROJECT_ROOT" != "$HOME" ]]; then
    log_info "Legacy project-isolated sync for root: $PROJECT_ROOT"
    LOCAL_DIR="$PROJECT_ROOT/.cavemem"
    LOCAL_DB="$LOCAL_DIR/data.db"
    REMOTE_DIR="$PROJECT_ROOT/.cavemem"
    REMOTE_DB="$REMOTE_DIR/data.db"
    REMOTE_PROJECT_ROOT="$PROJECT_ROOT"
    SYNC_MODE="file"
else
    LOCAL_DIR="$HOME/.cavemem"
    LOCAL_DB="$LOCAL_DIR/data.db"
    REMOTE_DIR=".cavemem"
    REMOTE_DB="$REMOTE_DIR/data.db"
    REMOTE_PROJECT_ROOT="$HOME"
    SYNC_MODE="file"
fi

# Ensure config directory exists
mkdir -p "$LOCAL_DIR"

load_config() {
    # Always load connection details from global settings to share them
    local global_config="$HOME/.cavemem/sync_config.json"
    if [ -f "$global_config" ]; then
        REMOTE_USER=$(node -p "require('$global_config').remoteUser || ''" 2>/dev/null || echo "")
        REMOTE_HOST=$(node -p "require('$global_config').remoteHost || ''" 2>/dev/null || echo "")
        REMOTE_PORT=$(node -p "require('$global_config').remotePort || '22'" 2>/dev/null || echo "22")
    elif [ -f "$CONFIG_FILE" ]; then
        REMOTE_USER=$(node -p "require('$CONFIG_FILE').remoteUser || ''" 2>/dev/null || echo "")
        REMOTE_HOST=$(node -p "require('$CONFIG_FILE').remoteHost || ''" 2>/dev/null || echo "")
        REMOTE_PORT=$(node -p "require('$CONFIG_FILE').remotePort || '22'" 2>/dev/null || echo "22")
    else
        REMOTE_USER=""
        REMOTE_HOST=""
        REMOTE_PORT="22"
    fi
}

save_config() {
    cat <<_EOF_ > "$CONFIG_FILE"
{
  "remoteUser": "$REMOTE_USER",
  "remoteHost": "$REMOTE_HOST",
  "remotePort": "$REMOTE_PORT"
}
_EOF_
    chmod 600 "$CONFIG_FILE"
}

setup_connection() {
    echo -e "${CYAN}=== Network Sync Configuration ===${RESET}"
    read -rp "Enter remote username (default: $USER): " input_user
    REMOTE_USER="${input_user:-$USER}"

    read -rp "Enter remote host IP/Hostname: " input_host
    if [ -z "$input_host" ]; then
        log_error "Remote host cannot be empty."
        exit 1
    fi
    REMOTE_HOST="$input_host"

    read -rp "Enter SSH port (default: 22): " input_port
    REMOTE_PORT="${input_port:-22}"

    save_config
    log_success "Configuration saved securely to ${CONFIG_FILE}"
}

check_connection() {
    if [ -z "${REMOTE_HOST:-}" ]; then
        log_error "No sync connection configured. Please run: $0 setup"
        exit 1
    fi

    log_info "Testing SSH connection to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}..."
    if ssh -p "$REMOTE_PORT" -o ConnectTimeout=5 "${REMOTE_USER}@${REMOTE_HOST}" "echo 'SSH Connection successful!'" >/dev/null 2>&1; then
        log_success "Connection verified."
    else
        log_error "Could not connect to remote host. Please check network/SSH configuration and make sure SSH keys are set up."
        exit 1
    fi
}

stop_workers() {
    log_info "Stopping local cavemem worker..."
    cavemem stop >/dev/null 2>&1 || HOME="$PROJECT_ROOT" cavemem stop >/dev/null 2>&1 || true

    log_info "Stopping remote cavemem worker..."
    ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "cavemem stop" >/dev/null 2>&1 || true

    log_info "Waiting for database files to release safely..."
    sleep 2
}

start_workers() {
    # v2 stack auto-starts via 'cavemem status' (ensure_server); legacy needs 'cavemem start'
    log_info "Restarting local cavemem worker..."
    cavemem status >/dev/null 2>&1 || HOME="$PROJECT_ROOT" cavemem start >/dev/null 2>&1 || true

    log_info "Restarting remote cavemem worker..."
    ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "cavemem status >/dev/null 2>&1 || cavemem start >/dev/null 2>&1" >/dev/null 2>&1 || true
}

checkpoint_all_local() {
    if [ "$SYNC_MODE" = "dir" ]; then
        for db in "$LOCAL_DIR"/*.db; do
            [ -f "$db" ] || continue
            sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || true
        done
    else
        sqlite3 "$LOCAL_DB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || true
    fi
}

checkpoint_all_remote() {
    if [ "$SYNC_MODE" = "dir" ]; then
        ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
            "for db in $REMOTE_DIR/*.db; do [ -f \"\$db\" ] && sqlite3 \"\$db\" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || true; done" \
            >/dev/null 2>&1 || true
    else
        ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
            "sqlite3 $REMOTE_DB 'PRAGMA wal_checkpoint(TRUNCATE);'" >/dev/null 2>&1 || true
    fi
}

sync_pull() {
    check_connection
    stop_workers

    log_info "Checkpointing remote database(s)..."
    checkpoint_all_remote

    log_info "Pulling remote database from ${REMOTE_HOST}..."
    if [ "$SYNC_MODE" = "dir" ]; then
        mkdir -p "$LOCAL_DIR"
        if rsync -avz --delete --exclude='*-wal' --exclude='*-shm' \
                -e "ssh -p $REMOTE_PORT" \
                "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_DIR/" "$LOCAL_DIR/"; then
            checkpoint_all_local
            log_success "Databases pulled from remote host."
        else
            log_error "Failed to pull databases."
        fi
    else
        if rsync -avz -e "ssh -p $REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_DB" "$LOCAL_DB"; then
            sqlite3 "$LOCAL_DB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || true
            log_success "Database pulled from remote host."
        else
            log_error "Failed to pull database."
        fi
    fi

    start_workers
}

sync_push() {
    check_connection
    stop_workers

    log_info "Checkpointing local database(s)..."
    checkpoint_all_local

    log_info "Pushing local database(s) to ${REMOTE_HOST}..."
    if [ "$SYNC_MODE" = "dir" ]; then
        ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
            "mkdir -p $REMOTE_DIR && find $REMOTE_DIR -name '*-wal' -delete -o -name '*-shm' -delete" \
            >/dev/null 2>&1 || true
        if rsync -avz --delete --exclude='*-wal' --exclude='*-shm' \
                -e "ssh -p $REMOTE_PORT" \
                "$LOCAL_DIR/" "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_DIR/"; then
            log_success "Databases pushed to remote host."
        else
            log_error "Failed to push databases."
        fi
    else
        ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
            "mkdir -p $REMOTE_DIR && rm -f $REMOTE_DB-wal $REMOTE_DB-shm"
        if rsync -avz -e "ssh -p $REMOTE_PORT" "$LOCAL_DB" "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_DB"; then
            log_success "Database pushed to remote host."
        else
            log_error "Failed to push database."
        fi
    fi

    start_workers
}

show_status() {
    check_connection

    log_info "Checking local database(s)..."
    if [ "$SYNC_MODE" = "dir" ]; then
        if [ -d "$LOCAL_DIR" ] && compgen -G "$LOCAL_DIR/*.db" >/dev/null; then
            LOCAL_TIME=$(stat -c %Y "$LOCAL_DIR"/*.db 2>/dev/null | sort -nr | head -1)
            LOCAL_SIZE=$(du -sb "$LOCAL_DIR"/*.db 2>/dev/null | awk '{s+=$1} END {print s}')
            log_info "Local: $(find "$LOCAL_DIR" -maxdepth 1 -name '*.db' | wc -l) DB(s) · newest: $(date -d @"$LOCAL_TIME") · total $LOCAL_SIZE bytes"
        else
            log_warn "No local DBs found at $LOCAL_DIR."
            LOCAL_TIME=0
        fi
    else
        if [ -f "$LOCAL_DB" ]; then
            LOCAL_TIME=$(stat -c %Y "$LOCAL_DB")
            LOCAL_SIZE=$(stat -c %s "$LOCAL_DB")
            log_info "Local DB: $(date -d @"$LOCAL_TIME") ($LOCAL_SIZE bytes)"
        else
            log_warn "Local DB file does not exist yet."
            LOCAL_TIME=0
        fi
    fi

    log_info "Checking remote database(s)..."
    if [ "$SYNC_MODE" = "dir" ]; then
        REMOTE_STAT=$(ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
            "find $REMOTE_DIR -maxdepth 1 -name '*.db' -printf '%T@ %s\n' 2>/dev/null | sort -nr | head -1" || echo "0 0")
    else
        REMOTE_STAT=$(ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "stat -c '%Y %s' $REMOTE_DB 2>/dev/null" || echo "0 0")
    fi
    REMOTE_TIME=$(echo "$REMOTE_STAT" | cut -d' ' -f1 | cut -d. -f1)
    REMOTE_SIZE=$(echo "$REMOTE_STAT" | cut -d' ' -f2)
    REMOTE_TIME=${REMOTE_TIME:-0}

    if [ "$REMOTE_TIME" -gt 0 ]; then
        log_info "Remote DB: $(date -d @"$REMOTE_TIME") ($REMOTE_SIZE bytes)"
    else
        log_warn "Remote DB file does not exist yet."
    fi

    if [ "$LOCAL_TIME" -eq 0 ] && [ "$REMOTE_TIME" -eq 0 ]; then
        log_warn "No database found on either host."
    elif [ "$LOCAL_TIME" -gt "$REMOTE_TIME" ]; then
        log_success "Local database is NEWER than remote (by $((LOCAL_TIME - REMOTE_TIME)) seconds). You should PUSH."
    elif [ "$REMOTE_TIME" -gt "$LOCAL_TIME" ]; then
        log_warn "Remote database is NEWER than local (by $((REMOTE_TIME - LOCAL_TIME)) seconds). You should PULL."
    else
        log_success "Databases are perfectly in sync."
    fi
}

# Main routing
load_config

case "${1:-}" in
    setup)
        setup_connection
        ;;
    push)
        sync_push
        ;;
    pull)
        sync_pull
        ;;
    status)
        show_status
        ;;
    *)
        echo -e "${CYAN}🛸 cavemem-sync - Secure Network Memory Sync Utility${RESET}"
        echo -e "Usage: \$0 {setup|status|push|pull}"
        echo -e "  - ${GREEN}setup${RESET}  : Configure remote connection (SSH-based)"
        echo -e "  - ${GREEN}status${RESET} : Compare local and remote database dates"
        echo -e "  - ${GREEN}push${RESET}   : Send local memory database to remote host"
        echo -e "  - ${GREEN}pull${RESET}   : Fetch remote memory database to local host"
        exit 1
        ;;
esac
