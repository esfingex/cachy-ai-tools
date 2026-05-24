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

# 1. Install NodeJS and NPM if missing
if command -v node &>/dev/null && command -v npm &>/dev/null; then
    log_info "NodeJS and NPM are already installed: $(node -v)"
else
    log_info "NodeJS/NPM not found. Bootstrapping via pacman..."
    if pacman -S --needed --noconfirm nodejs npm; then
        log_success "Successfully installed NodeJS and NPM."
    else
        log_error "Failed to install Node/NPM. Check your repositories or internet connection."
        exit 1
    fi
fi

# 2. Install cavemem globally
log_info "Installing 'cavemem' globally via npm..."
if npm install -g cavemem; then
    log_success "Successfully installed 'cavemem' globally."
else
    log_error "Failed to install 'cavemem' global package."
    exit 1
fi

# 3. Initialize cavemem status for target user
log_info "Verifying 'cavemem' installation status..."
if sudo -u "$TARGET_USER" command -v cavemem &>/dev/null; then
    sudo -u "$TARGET_USER" cavemem status || log_warn "Could not read cavemem status, initialization pending."
else
    log_warn "'cavemem' command is not immediately visible in user PATH. You may need to reopen your terminal."
fi

log_success "Ecosystem setup completed successfully!"

# Output helper instructions
echo -e "\n${YELLOW}🛸 Next Steps & Usage Reference:${RESET}"
echo -e "  - ${CYAN}cavemem status${RESET}                  : Verify database and session status"
echo -e "  - ${CYAN}cavemem viewer${RESET}                  : Launch local web UI at http://127.0.0.1:37777"
echo -e "  - ${CYAN}npx skills add JuliusBrussee/caveman${RESET} : Add the token compressor skill to your local agent"
echo -e "  - ${CYAN}cachy-ai-tools/prompts/ai-rules.md${RESET} : Use our pre-configured system prompt template"
echo -e "${YELLOW}Note: If you get a 'command not found' for cavemem immediately after install, please restart your terminal shell window.${RESET}\n"
