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

# 4.5 Ensure secure private database folder
CAVEMEM_USER_HOME="${HOME:-/home/$(whoami)}"
CAVEMEM_PRIVATE_DBS="$CAVEMEM_USER_HOME/.cavemem/dbs"
log_info "Ensuring secure database directory at $CAVEMEM_PRIVATE_DBS..."
mkdir -p "$CAVEMEM_PRIVATE_DBS"
if [ -d "$STACK_DIR/dbs" ]; then
    log_info "Migrating legacy local DB files..."
    mv "$STACK_DIR/dbs"/*.db* "$CAVEMEM_PRIVATE_DBS/" 2>/dev/null || true
    rmdir "$STACK_DIR/dbs" 2>/dev/null || true
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
