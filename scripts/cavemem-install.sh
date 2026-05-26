#!/usr/bin/env bash
# ==============================================================================
#   cachy-ai-tools - cavemem-install.sh
#   Purpose: Install the local CaveMem Node stack (server + CLI + symlink)
#   Idempotent: re-running upgrades deps and refreshes symlink.
# ==============================================================================
set -euo pipefail

CYAN="\e[1;36m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
RESET="\e[0m"

log_info()  { echo -e "${CYAN}[*] $*${RESET}"; }
log_ok()    { echo -e "${GREEN}[OK] $*${RESET}"; }
log_warn()  { echo -e "${YELLOW}[!] $*${RESET}"; }
log_error() { echo -e "${RED}[ERROR] $*${RESET}" >&2; }

# Repo layout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STACK_DIR="$REPO_ROOT/cavemem-stack"
CLI_SRC="$SCRIPT_DIR/cavemem.sh"

# Target install path
BIN_DIR="${CAVEMEM_BIN_DIR:-/usr/local/bin}"
BIN_LINK="$BIN_DIR/cavemem"

if [ ! -d "$STACK_DIR" ]; then
    log_error "Stack dir not found at $STACK_DIR. Make sure you're running this from a cachy-ai-tools clone."
    exit 1
fi

# 1. Node check
log_info "Checking Node.js / npm..."
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    log_error "Node.js or npm not in PATH."
    log_warn "Install via: sudo pacman -S nodejs-lts-jod npm"
    exit 1
fi

NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 18 ]; then
    log_error "Node $(node -v) is too old. Need >= 18 (recommend LTS 22)."
    exit 1
fi
if [ "$NODE_MAJOR" -ge 25 ]; then
    log_warn "Node $(node -v) is >= v25. better-sqlite3 may need rebuild."
fi
log_ok "Node $(node -v) detected."

# 2. Install deps
log_info "Installing Node deps in $STACK_DIR..."
(
    cd "$STACK_DIR"
    npm install --omit=dev --no-audit --no-fund
)
log_ok "Dependencies installed."

# 3. Pre-warm the model (downloads ~80MB on first run)
log_info "Pre-warming embedding model (HuggingFace MiniLM-L6-v2, ~80MB on first run)..."
(
    cd "$STACK_DIR"
    if ! node -e "import('./search-engine.js').then(m => m.getExtractor()).then(() => console.log('  -> model ready')).catch(e => { console.error(e); process.exit(1); })"; then
        log_warn "Model warm-up failed. First request will download lazily."
    fi
)

# 4. Install CLI symlink
log_info "Installing 'cavemem' CLI to $BIN_LINK..."
if [ ! -w "$BIN_DIR" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        log_error "$BIN_DIR is not writable. Re-run with sudo, or set CAVEMEM_BIN_DIR=\$HOME/.local/bin"
        exit 1
    fi
fi

chmod +x "$CLI_SRC"
ln -sf "$CLI_SRC" "$BIN_LINK"
log_ok "Linked: $BIN_LINK -> $CLI_SRC"

# 4.5 Ensure secure private database folder with per-project subdirectory layout
CAVEMEM_USER_HOME="${HOME:-/home/$(whoami)}"
CAVEMEM_PRIVATE_DBS="$CAVEMEM_USER_HOME/.cavemem/dbs"
log_info "Ensuring database directory at $CAVEMEM_PRIVATE_DBS..."
mkdir -p "$CAVEMEM_PRIVATE_DBS"

# Migrate legacy in-repo dbs/ folder to private location (old flat layout)
if [ -d "$STACK_DIR/dbs" ]; then
    log_info "Migrating legacy in-repo DB files..."
    for f in "$STACK_DIR/dbs"/*.db*; do
        [ -e "$f" ] && mv "$f" "$CAVEMEM_PRIVATE_DBS/" 2>/dev/null || true
    done
    rmdir "$STACK_DIR/dbs" 2>/dev/null || true
fi

# Migrate flat layout (dbs/<project>.db) → subdirectory layout (dbs/<project>/<project>.db)
log_info "Checking for flat-layout DB files to migrate..."
_MIGRATED=0
for flat_db in "$CAVEMEM_PRIVATE_DBS"/*.db; do
    [ -e "$flat_db" ] || continue
    proj_name=$(basename "$flat_db" .db)
    proj_dir="$CAVEMEM_PRIVATE_DBS/$proj_name"
    mkdir -p "$proj_dir"
    # Checkpoint WAL before moving (requires sqlite3)
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$flat_db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    fi
    mv "$flat_db" "$proj_dir/${proj_name}.db"
    [ -f "${flat_db}-shm" ] && mv "${flat_db}-shm" "$proj_dir/${proj_name}.db-shm" 2>/dev/null || true
    [ -f "${flat_db}-wal" ] && mv "${flat_db}-wal" "$proj_dir/${proj_name}.db-wal" 2>/dev/null || true
    log_ok "Migrated: ${proj_name}.db → ${proj_name}/${proj_name}.db"
    _MIGRATED=$((_MIGRATED + 1))
done
[ "$_MIGRATED" -gt 0 ] && log_ok "Migrated $_MIGRATED DB(s) to new per-project subdirectory layout."
[ "$_MIGRATED" -eq 0 ] && log_info "DB layout already up to date (per-project subdirectories)."

# 4.7 Auto-seed common knowledge if common.json exists
COMMON_SEED="$REPO_ROOT/knowledge/common.json"
if [ -f "$COMMON_SEED" ]; then
    log_info "Found common knowledge seed at $COMMON_SEED"
    
    # Determine the non-root user to run the seed command as to avoid running the server as root
    RUN_USER=""
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        RUN_USER="$SUDO_USER"
    elif [ "$(id -u)" -ne 0 ]; then
        RUN_USER="$(whoami)"
    fi
    
    if [ -n "$RUN_USER" ]; then
        log_info "Seeding common knowledge for user '$RUN_USER'..."
        # Run the seed command as the correct non-root user. 
        # This will automatically start the user-space cavemem server if not running.
        if [ "$(id -u)" -eq 0 ]; then
            sudo -u "$RUN_USER" env PATH="$PATH" HOME="/home/$RUN_USER" CAVEMEM_BIN_DIR="$BIN_DIR" "$CLI_SRC" seed --file "$COMMON_SEED" || log_warn "Auto-seeding skipped or failed."
        else
            "$CLI_SRC" seed --file "$COMMON_SEED" || log_warn "Auto-seeding skipped or failed."
        fi
    else
        log_warn "Running as root and cannot determine non-root SUDO_USER. Skipping auto-seeding."
    fi
fi

# 5. Optional: systemd user service (recommended for always-on background)
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
INSTALL_UNIT="${CAVEMEM_INSTALL_UNIT:-no}"
if [ "$INSTALL_UNIT" = "yes" ]; then
    log_info "Installing systemd user unit..."
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "$SYSTEMD_USER_DIR/cavemem-stack.service" <<EOF
[Unit]
Description=CaveMem local memory server
After=network.target

[Service]
Type=simple
WorkingDirectory=$STACK_DIR
ExecStart=$(command -v node) server.js
Restart=on-failure
Environment=CAVEMEM_HOST=127.0.0.1
Environment=CAVEMEM_DBS_DIR=$CAVEMEM_PRIVATE_DBS

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    log_ok "Unit installed. Enable with: systemctl --user enable --now cavemem-stack.service"
fi

echo ""
log_ok "CaveMem stack ready."
echo ""
echo -e "  Try:"
echo -e "    ${CYAN}cavemem status${RESET}     # auto-starts server"
echo -e "    ${CYAN}cavemem web${RESET}        # open dashboard"
echo -e "    ${CYAN}cavemem add gotcha \"Some fact\" -t tag1,tag2${RESET}"
echo ""
echo -e "  Env overrides: ${YELLOW}CAVEMEM_SERVER_URL, CAVEMEM_STACK_DIR, CAVEMEM_BIN_DIR${RESET}"
echo -e "  Install systemd user unit: re-run with ${YELLOW}CAVEMEM_INSTALL_UNIT=yes${RESET}"
echo ""
