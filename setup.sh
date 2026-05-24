#!/bin/bash
# ==============================================================================
#   cachy-ai-tools - setup.sh
#   Purpose: Automated installer for Caveman & Cavemem AI Optimizers Stack
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

# Pre-checks
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)."
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ]; then
    TARGET_HOME="/root"
else
    TARGET_HOME="/home/$TARGET_USER"
fi

log_info "Initializing Cachy AI Tools ecosystem for user '${TARGET_USER}'..."

# 1. Install NodeJS and NPM if missing, or handle incompatible Node 25+ versions
if command -v node &>/dev/null && command -v npm &>/dev/null; then
    NODE_VERSION_STR=$(node -v)
    NODE_MAJOR=$(echo "$NODE_VERSION_STR" | sed 's/v//' | cut -d. -f1 || echo "0")
    
    if [ "$NODE_MAJOR" -ge 25 ]; then
        log_warn "Your NodeJS version ($NODE_VERSION_STR) is >= v25. Native SQLite3 bindings do not support Node v25+."
        log_info "Switching to NodeJS stable LTS (nodejs-lts-jod, v22) to avoid addon compilation errors..."
        
        # Remove conflicting package explicitly to prevent pacman aborting on --noconfirm defaults
        log_info "Removing conflicting standard nodejs package..."
        pacman -Rdd --noconfirm nodejs || log_warn "Could not remove standard nodejs package safely."
        
        if pacman -S --noconfirm nodejs-lts-jod npm; then
            log_success "Successfully switched to NodeJS LTS (Jod: $(node -v))."
        else
            log_error "Failed to switch NodeJS to LTS version. Please run: sudo pacman -S nodejs-lts-jod npm"
            exit 1
        fi
    else
        log_info "NodeJS and NPM are already installed and compatible: $NODE_VERSION_STR"
    fi
else
    log_info "NodeJS or NPM not fully found. Bootstrapping stable LTS via pacman..."
    
    # Check if standard nodejs is installed and conflicts
    if pacman -Q nodejs &>/dev/null && ! pacman -Q nodejs-lts-jod &>/dev/null; then
        log_info "Removing conflicting standard nodejs package before LTS install..."
        pacman -Rdd --noconfirm nodejs || log_warn "Could not remove standard nodejs package safely."
    fi
    
    if pacman -S --noconfirm nodejs-lts-jod npm; then
        log_success "Successfully installed NodeJS LTS and NPM."
    else
        log_error "Failed to install Node LTS / NPM. Check your repositories or internet connection."
        exit 1
    fi
fi

# 2. Install cavemem and local search dependencies globally
log_info "Installing 'cavemem' and local semantic search engine (@xenova/transformers) globally via npm..."
if npm install -g cavemem @xenova/transformers; then
    log_success "Successfully installed 'cavemem' and '@xenova/transformers' globally."
else
    log_error "Failed to install global packages."
    exit 1
fi

# 3. Initialize cavemem status for target user
log_info "Verifying 'cavemem' installation status..."
if sudo -u "$TARGET_USER" command -v cavemem &>/dev/null; then
    sudo -u "$TARGET_USER" cavemem status || log_warn "Could not read cavemem status, initialization pending."
else
    log_warn "'cavemem' command is not immediately visible in user PATH. You may need to reopen your terminal."
fi

# 4. Integrate cavemem as an MCP server for the IDE
log_info "Configuring cavemem as an MCP server for Antigravity IDE..."
MCP_DIR="${TARGET_HOME}/.gemini/config"
MCP_CONFIG="${MCP_DIR}/mcp_config.json"

# Create directory if it doesn't exist
mkdir -p "$MCP_DIR"
chown -R "${TARGET_USER}:${TARGET_USER}" "$MCP_DIR"

if [ ! -f "$MCP_CONFIG" ] || [ ! -s "$MCP_CONFIG" ]; then
    # Create a fresh config if missing or empty
    log_info "Creating new mcp_config.json..."
    echo '{"mcpServers": {"cavemem": {"command": "/usr/bin/cavemem", "args": ["mcp"]}}}' > "$MCP_CONFIG"
else
    # Update existing config using Node since it is guaranteed to be installed
    log_info "Updating existing mcp_config.json..."
    node -e '
        const fs = require("fs");
        const file = process.argv[1];
        let data = {};
        try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch(e) {}
        data.mcpServers = data.mcpServers || {};
        if (!data.mcpServers.cavemem) {
            data.mcpServers.cavemem = { command: "/usr/bin/cavemem", args: ["mcp"] };
            fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
        }
    ' "$MCP_CONFIG"
fi
chown "${TARGET_USER}:${TARGET_USER}" "$MCP_CONFIG"
log_success "MCP configuration verified at ${MCP_CONFIG}."

# 5. Install caveman skills exclusively for the antigravity agent
log_info "Installing caveman skills exclusively for the Antigravity agent..."
if command -v npx &>/dev/null; then
    # Global installation
    log_info "Installing global caveman skills..."
    sudo -u "$TARGET_USER" npx -y skills add JuliusBrussee/caveman -g --agent antigravity -y || log_warn "Could not install global caveman skills."
    
    # Local installation
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    log_info "Installing project-level caveman skills in ${SCRIPT_DIR}..."
    cd "$SCRIPT_DIR"
    sudo -u "$TARGET_USER" npx -y skills add JuliusBrussee/caveman --agent antigravity -y || log_warn "Could not install local caveman skills."
fi

log_success "Ecosystem setup completed successfully!"

# Output helper instructions
echo -e "\n${YELLOW}🛸 Next Steps & Usage Reference:${RESET}"
echo -e "  - ${CYAN}cavemem status${RESET}                  : Verify database and session status"
echo -e "  - ${CYAN}cavemem viewer${RESET}                  : Launch local web UI at http://127.0.0.1:37777"
echo -e "  - ${CYAN}npx skills add JuliusBrussee/caveman${RESET} : Add the token compressor skill to your local agent"
echo -e "  - ${CYAN}cachy-ai-tools/prompts/ai-rules.md${RESET} : Use our pre-configured system prompt template"
echo -e "${YELLOW}Note: If you get a 'command not found' for cavemem immediately after install, please restart your terminal shell window.${RESET}\n"
