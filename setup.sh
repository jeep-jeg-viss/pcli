#!/bin/bash
#===============================================================================
# PCLI Personal Setup Script - Production Version
# Version: 2.0.0
# Description: Automated personal development environment setup
# Usage: ./setup.sh (DO NOT run as root)
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.env"
readonly LOG_FILE="${HOME}/.pcli_setup.log"
readonly TARGET_DIR_DEFAULT="$HOME/code"

#-------------------------------------------------------------------------------
# COLORS & FORMATTING
#-------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# LOGGING FUNCTIONS
#-------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        INFO)  echo -e "${BLUE}[INFO]${NC} $message" ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
}

log_info() { log "INFO" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

#-------------------------------------------------------------------------------
# CLEANUP & ERROR HANDLING
#-------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script exited with error code: $exit_code"
        log_error "Check log file: $LOG_FILE"
    fi
}
trap cleanup EXIT

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

#-------------------------------------------------------------------------------
# UTILITY FUNCTIONS
#-------------------------------------------------------------------------------
exists() {
    command -v "$1" >/dev/null 2>&1
}

apt_installed() {
    dpkg -s "$1" &>/dev/null
}

is_sourced() {
    [ "${BASH_SOURCE[0]}" != "${0}" ]
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This command requires root privileges. Please run with sudo."
    fi
}

require_normal_user() {
    if [ "$(id -u)" -eq 0 ]; then
        error_exit "Do not run as root. Run as your normal user."
    fi
}

#-------------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
#-------------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check if running as root
    require_normal_user
    
    # Check if running on supported OS
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            log_warn "Unsupported OS: $ID. Script tested on Ubuntu/Debian."
        fi
    else
        log_warn "Cannot detect OS. Continuing with caution."
    fi
    
    # Check disk space (minimum 5GB free)
    local available_space
    available_space=$(df -m "$HOME" | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 5120 ]; then
        error_exit "Insufficient disk space. Need at least 5GB free."
    fi
    
    # Validate config file permissions if it exists
    if [ -f "$CONFIG_FILE" ]; then
        local perms
        perms=$(stat -c %a "$CONFIG_FILE" 2>/dev/null || stat -f %Lp "$CONFIG_FILE" 2>/dev/null)
        if [ "$perms" != "600" ]; then
            log_warn "config.env should be 600 (private). Fixing permissions..."
            chmod 600 "$CONFIG_FILE"
        fi
    fi
    
    log_success "Pre-flight checks passed."
}

#-------------------------------------------------------------------------------
# PATH MANAGEMENT
#-------------------------------------------------------------------------------
ensure_path_in_shell() {
    local line='export PATH="$HOME/.local/bin:$PATH"'
    local added=0
    
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
            if ! grep -qF '.local/bin' "$rc" 2>/dev/null; then
                echo "" >> "$rc"
                echo "# Added by pcli setup ($(date '+%Y-%m-%d'))" >> "$rc"
                echo "$line" >> "$rc"
                added=1
            fi
        else
            touch "$rc"
            echo "" >> "$rc"
            echo "# Added by pcli setup ($(date '+%Y-%m-%d'))" >> "$rc"
            echo "$line" >> "$rc"
            added=1
        fi
    done
    
    if [ $added -eq 1 ]; then
        log_info "PATH updated in shell configuration files."
    fi
}

#-------------------------------------------------------------------------------
# PACKAGE INSTALLATION
#-------------------------------------------------------------------------------
install_packages() {
    local -a packages=("$@")
    local -a needed=()
    
    for pkg in "${packages[@]}"; do
        if ! apt_installed "$pkg"; then
            needed+=("$pkg")
        fi
    done
    
    if [ ${#needed[@]} -gt 0 ]; then
        log_info "Installing packages: ${needed[*]}"
        sudo apt-get update -qq
        if ! sudo apt-get install -y "${needed[@]}"; then
            error_exit "Failed to install packages: ${needed[*]}"
        fi
        log_success "Packages installed successfully."
    else
        log_info "All packages already installed."
    fi
}

#-------------------------------------------------------------------------------
# INSTALLATION TASKS
#-------------------------------------------------------------------------------
task_update_system() {
    log_info "Updating system packages..."
    
    if ! sudo apt-get update -qq; then
        error_exit "Failed to update package lists."
    fi
    
    if ! sudo apt-get upgrade -y; then
        error_exit "Failed to upgrade packages."
    fi
    
    # Install core dependencies
    install_packages curl wget gpg coreutils build-essential git jq
    
    log_success "System update complete."
}

task_install_docker() {
    if exists docker; then
        log_info "Docker already installed."
        return 0
    fi
    
    log_info "Installing Docker Engine..."
    
    # Remove old versions
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Set up repository
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add user to docker group
    sudo usermod -aG docker "$USER"
    
    log_success "Docker installed. Log out and back in for group changes to take effect."
}

task_install_uv() {
    if exists uv; then
        log_info "uv already installed."
        return 0
    fi
    
    log_info "Installing uv (Python toolchain)..."
    
    if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
        error_exit "Failed to install uv."
    fi
    
    export PATH="$HOME/.local/bin:$PATH"
    log_success "uv installed successfully."
}

task_install_tools() {
    log_info "Installing common development tools..."
    install_packages xvfb vim
    
    # Additional useful tools
    install_packages htop tree ripgrep fd-find 2>/dev/null || true
    
    log_success "Development tools installed."
}

task_setup_aliases() {
    log_info "Setting up shell aliases..."
    
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || touch "$rc"
        
        if ! grep -q "alias nano='vim'" "$rc"; then
            {
                echo ""
                echo "# Added by pcli setup ($(date '+%Y-%m-%d'))"
                echo "alias nano='vim'"
                echo "export EDITOR='vim'"
            } >> "$rc"
        fi
    done
    
    log_success "Aliases configured."
}

task_setup_github() {
    if ! exists gh; then
        log_info "Installing GitHub CLI..."
        
        sudo mkdir -p -m 755 /etc/apt/keyrings
        wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        
        sudo apt-get update -qq
        install_packages gh
    else
        log_info "GitHub CLI already installed."
    fi
    
    log_info "Setting up GitHub authentication..."
    
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | gh auth login --with-token
        gh auth setup-git
        log_success "Authenticated using GITHUB_TOKEN."
    elif gh auth status &>/dev/null; then
        log_info "Already authenticated."
        gh auth setup-git
    else
        log_info "Running interactive GitHub authentication..."
        if ! gh auth login; then
            error_exit "GitHub authentication failed."
        fi
        gh auth setup-git
    fi
    
    log_success "GitHub setup complete."
}

task_clone_repos() {
    log_info "Starting repository selection..."
    
    # Ensure git is available
    if ! exists git; then
        log_info "Installing git (required for cloning)..."
        install_packages git
    fi
    
    # Ensure gh is available for API access
    if ! exists gh; then
        log_warn "GitHub CLI not found. Fetching repos via API will not work."
    fi
    
    # Ask for source
    local source_choice
    source_choice=$(whiptail --title "Repo Source" --menu "Where should we get repos from?" 15 60 3 \
        "1" "Config file only (config.env)" \
        "2" "GitHub API only (Fetch all my repos)" \
        "3" "Both (Merge lists)" \
        3>&1 1>&2 2>&3) || {
        log_info "Repo source selection cancelled."
        return 0
    }
    
    local all_urls=""
    
    # Get repos from config
    if [[ "$source_choice" == "1" || "$source_choice" == "3" ]]; then
        if [ -n "${REPOS:-}" ]; then
            # shellcheck disable=SC2206
            local repos_array=($REPOS)
            for r in "${repos_array[@]}"; do
                all_urls+="$r"$'\n'
            done
            log_info "Loaded ${#repos_array[@]} repos from config."
        else
            log_warn "REPOS not defined in config.env."
        fi
    fi
    
    # Get repos from GitHub API
    if [[ "$source_choice" == "2" || "$source_choice" == "3" ]]; then
        if exists gh && gh auth status &>/dev/null; then
            log_info "Fetching repos from GitHub API..."
            local api_urls
            api_urls=$(gh repo list --limit 500 --json url --jq '.[].url' 2>/dev/null) || {
                log_warn "Failed to fetch repos from GitHub API."
                api_urls=""
            }
            all_urls+="$api_urls"$'\n'
        else
            log_warn "GitHub CLI not authenticated. Skipping API fetch."
        fi
    fi
    
    # Remove empty lines and duplicates
    all_urls=$(echo "$all_urls" | grep -v "^$" | sort -u)
    
    if [ -z "$all_urls" ]; then
        log_warn "No repositories found to clone."
        return 0
    fi
    
    # Interactive selection with fzf
    log_info "Opening repository selector... (TAB to select multiple, ENTER to confirm)"
    local selected_repos
    selected_repos=$(echo "$all_urls" | fzf -m --height=40% --layout=reverse --border --prompt="Select Repos to Clone > ") || {
        log_info "Repository selection cancelled."
        return 0
    }
    
    if [ -z "$selected_repos" ]; then
        log_info "No repositories selected."
        return 0
    fi
    
    # Setup target directory
    local target_dir="${TARGET_DIR:-$TARGET_DIR_DEFAULT}"
    mkdir -p "$target_dir"
    
    log_info "Cloning repositories to $target_dir..."
    local cloned=0
    local skipped=0
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        local repo_name
        repo_name=$(basename "$repo_url" .git)
        
        if [ -d "$target_dir/$repo_name" ]; then
            log_info "Skipping $repo_name (already exists)"
            ((skipped++))
        else
            if git clone "$repo_url" "$target_dir/$repo_name"; then
                log_success "Cloned $repo_name"
                ((cloned++))
            else
                log_error "Failed to clone $repo_name"
            fi
        fi
    done <<< "$selected_repos"
    
    log_success "Clone complete: $cloned cloned, $skipped skipped."
}

#-------------------------------------------------------------------------------
# MAIN MENU
#-------------------------------------------------------------------------------
show_main_menu() {
    local choices
    
    choices=$(whiptail --title "PCLI Personal Setup" --checklist \
        "Select tasks to perform:" 20 78 12 \
        "UPDATE" "System Update & Core Packages" ON \
        "DOCKER" "Docker Engine & Compose" ON \
        "UV" "uv (Python Toolchain)" ON \
        "TOOLS" "XVFB, Vim & Dev Utils" ON \
        "ALIAS" "Shell Aliases (nano→vim)" OFF \
        "GITHUB" "GitHub CLI + Authentication" ON \
        "CLONE" "Clone Repositories (Interactive)" ON \
        3>&1 1>&2 2>&3) || {
        log_info "Setup cancelled by user."
        exit 0
    }
    
    if [ -z "$choices" ]; then
        log_info "No tasks selected."
        exit 0
    fi
    
    echo "$choices"
}

has_choice() {
    [[ "$1" == *"$2"* ]]
}

#-------------------------------------------------------------------------------
# MAIN EXECUTION
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "========================================"
    echo "  PCLI Personal Setup Script v2.0.0"
    echo "========================================"
    echo ""
    
    # Initialize
    preflight_checks
    
    # Load configuration
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1091
        source "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    else
        log_info "No config.env found. Using defaults."
    fi
    
    # Ensure PATH is set
    export PATH="$HOME/.local/bin:$PATH"
    ensure_path_in_shell
    
    # Show menu and get choices
    local choices
    choices=$(show_main_menu)
    
    # Execute selected tasks
    if has_choice "$choices" "UPDATE"; then
        task_update_system
    fi
    
    if has_choice "$choices" "DOCKER"; then
        task_install_docker
    fi
    
    if has_choice "$choices" "UV"; then
        task_install_uv
    fi
    
    if has_choice "$choices" "TOOLS"; then
        task_install_tools
    fi
    
    if has_choice "$choices" "ALIAS"; then
        task_setup_aliases
    fi
    
    if has_choice "$choices" "GITHUB"; then
        task_setup_github
    fi
    
    if has_choice "$choices" "CLONE"; then
        task_clone_repos
    fi
    
    # Completion
    echo ""
    log_success "========================================"
    log_success "  Setup Complete!"
    log_success "========================================"
    echo ""
    
    if is_sourced; then
        log_info "Script was sourced. Run 'source ~/.bashrc' or open new terminal."
    else
        log_info "Open a new terminal for all changes to take effect."
    fi
    
    log_info "Log file: $LOG_FILE"
}

# Run main function
main "$@"