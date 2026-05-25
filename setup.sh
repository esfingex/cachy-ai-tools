#!/bin/bash
# ==============================================================================
#   cachy-ai-tools - setup.sh
#   Purpose: Automated installer for Caveman & CaveMem AI Optimizers Stack
#
#   v2.0 (2026-05): switched from the external npm 'cavemem' package to a
#   self-hosted CaveMem stack (cavemem-stack/) for parity with the Windows
#   ia-tools-win project. The local stack uses better-sqlite3 + transformers v3
#   and exposes a REST API + EJS dashboard.
# ==============================================================================
set -euo pipefail

# ANSI color codes
CYAN="\e[1;36m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
RESET="\e[0m"

log_info()    { echo -e "${CYAN}[*] $1${RESET}"; }
log_success() { echo -e "${GREEN}[+] $1${RESET}"; }
log_warn()    { echo -e "${YELLOW}[!] $1${RESET}"; }
log_error()   { echo -e "${RED}[ERROR] $1${RESET}" >&2; }

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

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log_info "Initializing Cachy AI Tools ecosystem for user '${TARGET_USER}'..."

# 1. NodeJS / NPM
if command -v node &>/dev/null && command -v npm &>/dev/null; then
    NODE_VERSION_STR=$(node -v)
    NODE_MAJOR=$(echo "$NODE_VERSION_STR" | sed 's/v//' | cut -d. -f1 || echo "0")

    if [ "$NODE_MAJOR" -ge 25 ]; then
        log_warn "Your NodeJS version ($NODE_VERSION_STR) is >= v25. Native SQLite bindings may need rebuild."
        log_info "Switching to NodeJS stable LTS (nodejs-lts-jod, v22) for compatibility..."
        log_info "Removing conflicting standard nodejs package..."
        pacman -Rdd --noconfirm nodejs || log_warn "Could not remove standard nodejs package safely."

        if pacman -S --noconfirm nodejs-lts-jod npm; then
            log_success "Switched to NodeJS LTS (Jod: $(node -v))."
        else
            log_error "Failed to switch NodeJS to LTS version. Run: sudo pacman -S nodejs-lts-jod npm"
            exit 1
        fi
    else
        log_info "NodeJS and NPM already installed: $NODE_VERSION_STR"
    fi
else
    log_info "NodeJS / NPM not found. Bootstrapping stable LTS via pacman..."

    if pacman -Q nodejs &>/dev/null && ! pacman -Q nodejs-lts-jod &>/dev/null; then
        log_info "Removing conflicting standard nodejs package before LTS install..."
        pacman -Rdd --noconfirm nodejs || log_warn "Could not remove standard nodejs package safely."
    fi

    if pacman -S --noconfirm nodejs-lts-jod npm; then
        log_success "Installed NodeJS LTS and NPM."
    else
        log_error "Failed to install Node LTS / NPM. Check repositories / network."
        exit 1
    fi
fi

# 2. Build tools required by better-sqlite3 (node-gyp)
log_info "Ensuring native build tools (base-devel, python) for native bindings..."
pacman -S --noconfirm --needed base-devel python || log_warn "Could not verify base-devel/python (may already be present)."

# 3. Install the local CaveMem stack (cavemem-stack + cavemem CLI)
log_info "Installing local CaveMem stack from $REPO_ROOT/cavemem-stack ..."
INSTALLER="$REPO_ROOT/scripts/cavemem-install.sh"
if [ ! -f "$INSTALLER" ]; then
    log_error "Installer not found: $INSTALLER"
    exit 1
fi
chmod +x "$INSTALLER"

# Run installer as target user so npm cache + model cache land in their home;
# /usr/local/bin still requires root for the symlink, so re-elevate inside the script.
sudo -u "$TARGET_USER" CAVEMEM_BIN_DIR="$TARGET_HOME/.local/bin" bash "$INSTALLER" || \
    bash "$INSTALLER"   # fallback: run as root if user-mode install failed

# Make sure ~/.local/bin is on PATH (user shells)
SHELL_RC=""
if [ -f "$TARGET_HOME/.bashrc" ]; then SHELL_RC="$TARGET_HOME/.bashrc"; fi
if [ -f "$TARGET_HOME/.zshrc" ];  then SHELL_RC="$TARGET_HOME/.zshrc"; fi
if [ -n "$SHELL_RC" ] && ! grep -q '\.local/bin' "$SHELL_RC"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    log_info "Added ~/.local/bin to PATH in $SHELL_RC. Re-open shell."
fi

# 4. Integrate cavemem as an MCP server for the IDE (optional, preserved)
log_info "Configuring cavemem as an MCP server for Antigravity IDE..."
MCP_DIR="${TARGET_HOME}/.gemini/config"
MCP_CONFIG="${MCP_DIR}/mcp_config.json"

mkdir -p "$MCP_DIR"
chown -R "${TARGET_USER}:${TARGET_USER}" "$MCP_DIR"

if [ ! -f "$MCP_CONFIG" ] || [ ! -s "$MCP_CONFIG" ]; then
    log_info "Creating new mcp_config.json..."
    echo '{"mcpServers": {}}' > "$MCP_CONFIG"
    chown "${TARGET_USER}:${TARGET_USER}" "$MCP_CONFIG"
fi

CAVEMEM_BIN="$TARGET_HOME/.local/bin/cavemem"
[ -x /usr/local/bin/cavemem ] && CAVEMEM_BIN="/usr/local/bin/cavemem"

CONFIGURE_GITHUB="n"
if [ -t 0 ]; then
    echo -e -n "${YELLOW}[?] Configure the GitHub MCP Server now? (y/N): ${RESET}"
    read -r -t 20 RESPONSE || RESPONSE="n"
    [[ "$RESPONSE" =~ ^[Yy]$ ]] && CONFIGURE_GITHUB="y"
fi

if [ "$CONFIGURE_GITHUB" = "y" ]; then
    echo -n -e "${CYAN}[?] Enter your GitHub Personal Access Token (PAT): ${RESET}"
    read -s -r GIT_TOKEN
    echo ""

    if [ -n "$GIT_TOKEN" ]; then
        node -e '
            const fs = require("fs");
            const [file, cavememBin, gitToken] = process.argv.slice(1);
            let data = {};
            try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch(e) {}
            data.mcpServers = data.mcpServers || {};
            data.mcpServers.cavemem = { command: cavememBin, args: ["status"] };
            data.mcpServers["github-mcp-server"] = {
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"],
                env: { GITHUB_PERSONAL_ACCESS_TOKEN: gitToken }
            };
            fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
        ' "$MCP_CONFIG" "$CAVEMEM_BIN" "$GIT_TOKEN"
        log_success "GitHub MCP Server integrated."
    else
        log_warn "Empty GitHub token. Skipping GitHub MCP."
        node -e '
            const fs = require("fs");
            const [file, cavememBin] = process.argv.slice(1);
            let data = {};
            try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch(e) {}
            data.mcpServers = data.mcpServers || {};
            data.mcpServers.cavemem = { command: cavememBin, args: ["status"] };
            fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
        ' "$MCP_CONFIG" "$CAVEMEM_BIN"
    fi
else
    node -e '
        const fs = require("fs");
        const [file, cavememBin] = process.argv.slice(1);
        let data = {};
        try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch(e) {}
        data.mcpServers = data.mcpServers || {};
        data.mcpServers.cavemem = { command: cavememBin, args: ["status"] };
        fs.writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
    ' "$MCP_CONFIG" "$CAVEMEM_BIN"
fi
chown "${TARGET_USER}:${TARGET_USER}" "$MCP_CONFIG"
log_success "MCP configuration written to ${MCP_CONFIG}."

# 5. Install caveman skills for the agent (preserved)
log_info "Installing caveman skills (token compressor) for Antigravity agent..."
if command -v npx &>/dev/null; then
    sudo -u "$TARGET_USER" npx -y skills add JuliusBrussee/caveman -g --agent antigravity -y \
        || log_warn "Could not install caveman skills (non-fatal)."
fi

log_success "Ecosystem setup completed."

echo -e "\n${YELLOW}🛸 Next Steps:${RESET}"
echo -e "  - ${CYAN}cavemem status${RESET}      : verify stack (auto-starts server)"
echo -e "  - ${CYAN}cavemem web${RESET}         : open dashboard at http://127.0.0.1:3000"
echo -e "  - ${CYAN}cavemem add gotcha \"Some fact\" -t firebird,encoding${RESET}"
echo -e "  - ${CYAN}cavemem query \"firebird\"${RESET} : semantic search"
echo -e "  - ${CYAN}scripts/cavemem-sync.sh push${RESET} : push DB to another host"
echo -e "${YELLOW}NOTE: If 'cavemem: command not found', open a new terminal or run 'source ~/.bashrc'.${RESET}\n"
