#!/bin/bash
# =============================================================================
# Personal Development Environment Setup Script
# =============================================================================
# A comprehensive setup script for personal development environment
# Includes: System update, Docker, uv, tools, GitHub CLI, repository cloning
# =============================================================================

set -euo pipefail

# Ensure not running as root
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: Do not run as root. Run as your normal user."
    exit 1
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
LOG_FILE="${SCRIPT_DIR}/setup.log"

# Default values
DEFAULT_TARGET_DIR="${HOME}/code"
: "${TARGET_DIR:=$DEFAULT_TARGET_DIR}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$level" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE"
            ;;
    esac
}

log_section() {
    echo "" | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
    echo "  $*" | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
}

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
echo "Setup started at $(date)" > "$LOG_FILE"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if a command exists
exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if apt package is installed
apt_installed() {
    dpkg -s "$1" &>/dev/null
}

# Run command with sudo and error handling
run_sudo() {
    if ! sudo "$@"; then
        log ERROR "Failed to execute: sudo $*"
        return 1
    fi
}

# Run command and capture exit status
run_cmd() {
    if "$@"; then
        return 0
    else
        log ERROR "Failed to execute: $*"
        return 1
    fi
}

# Backup file before modification
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log INFO "Backed up $file to $backup"
    fi
}

# =============================================================================
# UBUNTU COMPATIBILITY DETECTION
# =============================================================================

detect_ubuntu_codename() {
    local codename=""
    if [ -f /etc/os-release ]; then
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    fi
    if [ -z "$codename" ] && [ -f /etc/lsb-release ]; then
        codename="$(. /etc/lsb-release && echo "$DISTRIB_CODENAME")"
    fi
    if [ -z "$codename" ]; then
        codename="$(lsb_release -cs 2>/dev/null || echo "")"
    fi
    if [ -z "$codename" ]; then
        codename="jammy"
    fi
    echo "$codename"
}

detect_architecture() {
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
    case "$arch" in
        i386|i486|i586|i686) arch="amd64" ;;
        arm64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac
    echo "$arch"
}

CODENAME="$(detect_ubuntu_codename)"
ARCH="$(detect_architecture)"

debug_info() {
    log INFO "Ubuntu codename: $CODENAME"
    log INFO "Architecture: $ARCH"
    log INFO "OS: $(. /etc/os-release && echo "$ID $VERSION_ID")"
    log INFO "curl: $(curl --version | head -1)"
}

install_lsb_release() {
    if ! command -v lsb_release &>/dev/null; then
        run_sudo apt-get install -y -qq lsb-release 2>/dev/null || true
    fi
}

download_with_retry() {
    local url="$1"
    local dest="$2"
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "$dest" 2>/dev/null; then
            return 0
        fi
        log WARN "Download attempt $attempt/$max_attempts failed for $url, retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

log INFO "Detecting system..."
install_lsb_release

# =============================================================================
# PATH CONFIGURATION
# =============================================================================

ensure_path_in_shell() {
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    local shell_configs=("$HOME/.bashrc" "$HOME/.zshrc")

    for rc in "${shell_configs[@]}"; do
        if [ -f "$rc" ]; then
            if ! grep -qF '.local/bin' "$rc" 2>/dev/null; then
                backup_file "$rc"
                echo "" >> "$rc"
                echo "# Added by pcli setup" >> "$rc"
                echo "$path_line" >> "$rc"
                log INFO "Added PATH to $rc"
            fi
        else
            touch "$rc"
            echo "$path_line" >> "$rc"
            log INFO "Created $rc with PATH configuration"
        fi
    done

    # Also add to profile for login shells
    if [ -f "$HOME/.profile" ] && ! grep -qF '.local/bin' "$HOME/.profile" 2>/dev/null; then
        backup_file "$HOME/.profile"
        echo "" >> "$HOME/.profile"
        echo "$path_line" >> "$HOME/.profile"
        log INFO "Added PATH to ~/.profile"
    fi
}

# Persist PATH for current session
export PATH="$HOME/.local/bin:$PATH"

# =============================================================================
# CONFIG FILE LOADING
# =============================================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log INFO "Loading configuration from $CONFIG_FILE"
        set -a  # Auto-export all variables
        source "$CONFIG_FILE"
        set +a
        log SUCCESS "Configuration loaded successfully"
    else
        log WARN "Config file not found at $CONFIG_FILE"
        log INFO "Using default configuration"
    fi
}

# Validate required config variables
validate_config() {
    local valid=true

    # Validate REPOS array if provided
    if [ -n "${REPOS+x}" ]; then
        if ! declare -p REPOS | grep -q 'declare -a'; then
            log ERROR "REPOS must be an array. Use: REPOS=(repo1 repo2)"
            valid=false
        fi
    fi

    # Validate TARGET_DIR if provided
    if [ -n "${TARGET_DIR+x}" ]; then
        if [ ! -d "$(dirname "$TARGET_DIR")" ]; then
            log ERROR "Parent directory for TARGET_DIR does not exist: $(dirname "$TARGET_DIR")"
            valid=false
        fi
    fi

    $valid
}

# =============================================================================
# SYSTEM PREREQUISITES
# =============================================================================

install_prerequisites() {
    log_section "Installing Prerequisites"

    # Check and install whiptail
    if ! exists whiptail; then
        log INFO "Installing whiptail..."
        run_sudo apt-get update -qq
        run_sudo apt-get install -y -qq whiptail
        log SUCCESS "whiptail installed"
    else
        log INFO "whiptail already installed"
    fi

    # Check and install fzf
    if ! exists fzf; then
        log INFO "Installing fzf..."
        run_sudo apt-get update -qq
        run_sudo apt-get install -y -qq fzf
        log SUCCESS "fzf installed"
    else
        log INFO "fzf already installed"
    fi
}

# =============================================================================
# SYSTEM UPDATE
# =============================================================================

do_system_update() {
    log_section "Updating System"

    log INFO "Running apt update..."
    run_sudo apt-get update -y -qq

    log INFO "Installing core packages..."
    run_sudo apt-get install -y -qq curl wget gpg ca-certificates build-essential git whiptail fzf xvfb vim

    log SUCCESS "System update complete"
}

# =============================================================================
# DOCKER INSTALLATION
# =============================================================================

install_docker() {
    log_section "Installing Docker"

    if exists docker; then
        log INFO "Docker already installed: $(docker --version)"
        return 0
    fi

    source /etc/os-release
    case "$VERSION_CODENAME" in
      jammy|noble|questing) ;;
      *)
        log ERROR "Unsupported Ubuntu release for Docker: $VERSION_CODENAME (supported: jammy, noble, questing)"
        return 1
        ;;
    esac

    debug_info

    log INFO "Installing Docker Engine and Compose..."

    # Remove old docker installations if any
    if apt_installed docker.io; then
        log INFO "Removing old docker.io package..."
        run_sudo apt-get remove -y -qq docker.io 2>/dev/null || true
    fi

    # Install prerequisites
    run_sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Create keyrings directory
    run_sudo mkdir -p -m 0755 /etc/apt/keyrings

    # Download and verify Docker GPG key
    log INFO "Downloading Docker GPG key..."
    if ! download_with_retry "https://download.docker.com/linux/ubuntu/gpg" "/tmp/docker.gpg"; then
        log ERROR "Failed to download Docker GPG key"
        return 1
    fi
    run_sudo mv /tmp/docker.gpg /etc/apt/keyrings/docker.asc
    run_sudo chmod a+r /etc/apt/keyrings/docker.asc

    log INFO "Adding Docker repository for $CODENAME ($ARCH)..."
    local docker_repo_file="/etc/apt/sources.list.d/docker.list"
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" | \
        sudo tee "$docker_repo_file" > /dev/null

    # Update and install Docker
    log INFO "Installing Docker packages..."
    run_sudo apt-get update -qq

    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )

    run_sudo apt-get install -y -qq "${docker_packages[@]}"

    # Add user to docker group
    if ! groups "$USER" | grep -q docker; then
        log INFO "Adding user to docker group..."
        run_sudo usermod -aG docker "$USER"
        log WARN "You need to log out and back in for docker group to take effect"
    fi

    # Verify installation
    if exists docker; then
        log SUCCESS "Docker installed: $(docker --version)"
    else
        log ERROR "Docker installation failed"
        return 1
    fi
}

# =============================================================================
# UV INSTALLATION
# =============================================================================

install_uv() {
    log_section "Installing uv"

    if exists uv; then
        log INFO "uv already installed: $(uv --version)"
        return 0
    fi

    log INFO "Installing uv (Python Tool)..."

    # Download and run uv installation script
    local install_script="/tmp/uv_install.sh"
    if ! download_with_retry "https://astral.sh/uv/install.sh" "$install_script"; then
        log ERROR "Failed to download uv installer"
        return 1
    fi

    # Verify script is not empty and looks reasonable
    if [ ! -s "$install_script" ]; then
        log ERROR "uv installer script is empty"
        rm -f "$install_script"
        return 1
    fi

    # Run installation (official method)
    if ! run_cmd sh "$install_script"; then
        log ERROR "Failed to install uv"
        rm -f "$install_script"
        return 1
    fi

    rm -f "$install_script"

    # Ensure PATH is updated
    export PATH="$HOME/.local/bin:$PATH"

    if exists uv; then
        log SUCCESS "uv installed: $(uv --version)"
    else
        log ERROR "uv installation failed"
        return 1
    fi
}

# =============================================================================
# DEVELOPMENT TOOLS
# =============================================================================

install_tools() {
    log_section "Installing Development Tools"

    local tools_to_install=()

    # Check each tool
    for tool in xvfb vim; do
        if ! apt_installed "$tool"; then
            tools_to_install+=("$tool")
        fi
    done

    if [ ${#tools_to_install[@]} -gt 0 ]; then
        log INFO "Installing tools: ${tools_to_install[*]}"
        run_sudo apt-get install -y -qq "${tools_to_install[@]}"
        log SUCCESS "Tools installed"
    else
        log INFO "Tools already installed"
    fi
}

# =============================================================================
# ALIAS CONFIGURATION
# =============================================================================

configure_aliases() {
    log_section "Configuring Aliases"

    local rc_file="$HOME/.bashrc"
    local alias_added=false

    # Backup before modification
    if [ -f "$rc_file" ]; then
        backup_file "$rc_file"
    fi

    # Add nano to vim alias
    if [ -f "$rc_file" ]; then
        if ! grep -q "alias nano='vim'" "$rc_file"; then
            echo "alias nano='vim'" >> "$rc_file"
            alias_added=true
        fi

        if ! grep -q "export EDITOR='vim'" "$rc_file"; then
            echo "export EDITOR='vim'" >> "$rc_file"
            alias_added=true
        fi
    fi

    if $alias_added; then
        log SUCCESS "Aliases configured in $rc_file"
    else
        log INFO "Aliases already configured"
    fi
}

# =============================================================================
# GITHUB CLI
# =============================================================================

install_github_cli() {
    log_section "Installing GitHub CLI"

    if exists gh; then
        log INFO "gh already installed: $(gh --version)"
        return 0
    fi

    log INFO "Installing GitHub CLI..."

    # Install prerequisites
    run_sudo apt-get install -y -qq wget gpg

    # Create keyrings directory
    run_sudo mkdir -p -m 755 /etc/apt/keyrings

    # Download and verify GitHub CLI keyring
    log INFO "Downloading GitHub CLI keyring..."
    if ! download_with_retry "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "/tmp/gh.gpg"; then
        log ERROR "Failed to download GitHub CLI keyring"
        return 1
    fi
    run_sudo mv /tmp/gh.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg
    run_sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

    # Add GitHub CLI repository
    local gh_repo_file="/etc/apt/sources.list.d/github-cli.list"
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
        sudo tee "$gh_repo_file" > /dev/null

    # Update and install
    run_sudo apt-get update -qq
    run_sudo apt-get install -y -qq gh

    if exists gh; then
        log SUCCESS "GitHub CLI installed: $(gh --version)"
    else
        log ERROR "GitHub CLI installation failed"
        return 1
    fi
}

# =============================================================================
# GITHUB AUTHENTICATION
# =============================================================================

authenticate_github() {
    log_section "Authenticating GitHub"

    if ! exists gh; then
        log ERROR "GitHub CLI not installed"
        return 1
    fi

    # Check if already authenticated
    if gh auth status &>/dev/null; then
        log INFO "Already authenticated with GitHub"
        gh auth setup-git
        return 0
    fi

    # Check for token in environment
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        log INFO "Authenticating with GITHUB_TOKEN..."
        if echo "$GITHUB_TOKEN" | gh auth login --with-token; then
            gh auth setup-git
            log SUCCESS "GitHub authentication successful"
            return 0
        else
            log ERROR "Failed to authenticate with GITHUB_TOKEN"
            return 1
        fi
    fi

    # Interactive authentication
    log INFO "Starting interactive GitHub authentication..."
    if gh auth login; then
        gh auth setup-git
        log SUCCESS "GitHub authentication successful"
    else
        log ERROR "GitHub authentication failed"
        return 1
    fi
}

# =============================================================================
# REPOSITORY CLONING
# =============================================================================

clone_repositories() {
    log_section "Cloning Repositories"

    # Check for gh CLI
    if ! exists gh; then
        log ERROR "GitHub CLI (gh) is required for repository cloning"
        return 1
    fi

    # Check GitHub authentication
    if ! gh auth status &>/dev/null; then
        log WARN "GitHub CLI not authenticated. Please run GitHub CLI setup first."
        return 1
    fi

    # Ask for source
    local source_choice
    source_choice=$(whiptail --title "Repo Source" --menu \
        "Where should we get repos from?" 15 60 3 \
        "1" "Config file only (config.env)" \
        "2" "GitHub API only (Fetch all my repos)" \
        "3" "Both (Merge lists)" 3>&1 1>&2 2>&3)

    if [ $? -ne 0 ] || [ -z "$source_choice" ]; then
        log INFO "Repository selection cancelled"
        return 0
    fi

    local all_urls=()

    # Get repos from config
    if [ "$source_choice" == "1" ] || [ "$source_choice" == "3" ]; then
        if [ -n "${REPOS+x}" ] && [ ${#REPOS[@]} -gt 0 ]; then
            log INFO "Adding ${#REPOS[@]} repos from config..."
            for repo in "${REPOS[@]}"; do
                # Validate URL format
                if [[ "$repo" =~ ^https?:// ]]; then
                    all_urls+=("$repo")
                else
                    log WARN "Invalid repo URL skipped: $repo"
                fi
            done
        else
            log WARN "No REPOS array found in config.env"
        fi
    fi

    # Get repos from GitHub API
    if [ "$source_choice" == "2" ] || [ "$source_choice" == "3" ]; then
        log INFO "Fetching repos from GitHub API..."
        local api_urls
        if api_urls=$(gh repo list --limit 500 --json url --jq '.[].url' 2>&1); then
            while IFS= read -r url; do
                [ -n "$url" ] && all_urls+=("$url")
            done <<< "$api_urls"
            log SUCCESS "Fetched repos from GitHub"
        else
            log ERROR "Failed to fetch repos from GitHub: $api_urls"
        fi
    fi

    # Check if we have any repos
    if [ ${#all_urls[@]} -eq 0 ]; then
        log WARN "No repositories found to clone"
        return 0
    fi

    # Remove duplicates
    local unique_urls
    unique_urls=$(printf '%s\n' "${all_urls[@]}" | sort -u)

    # Interactive selection with fzf
    log INFO "Opening repository selector..."
    echo "Use TAB to select multiple, ENTER to confirm"

    local selected_repos
    selected_repos=$(echo "$unique_urls" | fzf -m \
        --height=40% \
        --layout=reverse \
        --border \
        --prompt="Select Repos to Clone > ")

    if [ -z "$selected_repos" ]; then
        log INFO "No repositories selected"
        return 0
    fi

    # Create target directory
    local target_dir="${TARGET_DIR:-$DEFAULT_TARGET_DIR}"
    log INFO "Cloning to $target_dir"

    mkdir -p "$target_dir"

    # Clone selected repos
    local cloned=0
    local skipped=0
    local failed=0

    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue

        local repo_name
        repo_name=$(basename "$repo_url" .git)
        local repo_path="$target_dir/$repo_name"

        if [ -d "$repo_path" ]; then
            log INFO "Skipping $repo_name (already exists)"
            ((skipped++))
        else
            log INFO "Cloning $repo_name..."
            if git clone "$repo_url" "$repo_path" 2>&1 | tee -a "$LOG_FILE"; then
                log SUCCESS "Cloned $repo_name"
                ((cloned++))
            else
                log ERROR "Failed to clone $repo_name"
                ((failed++))
            fi
        fi
    done <<< "$selected_repos"

    log SUCCESS "Cloning complete: $cloned cloned, $skipped skipped, $failed failed"
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_menu() {
    local choices
    choices=$(whiptail --title "Personal Setup" --checklist \
        "Select tasks to run:" 20 78 12 \
        "UPDATE" "System Update (apt update/upgrade)" ON \
        "DOCKER" "Docker Engine & Compose" ON \
        "UV" "uv (Python Tool)" ON \
        "TOOLS" "XVFB, Vim, Common Utils" ON \
        "ALIAS" "Alias nano to vim" OFF \
        "GITHUB" "GitHub CLI (gh) + Auth" ON \
        "CLONE" "Clone Repositories (Interactive)" ON \
        3>&1 1>&2 2>&3)

    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        echo "Cancelled."
        exit 0
    fi

    echo "$choices"
}

has_choice() {
    [[ "$1" == *"$2"* ]]
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_section "Personal Development Environment Setup"

    # Load configuration
    load_config

    # Validate configuration
    if ! validate_config; then
        log ERROR "Configuration validation failed"
        exit 1
    fi

    # Ensure PATH configuration
    ensure_path_in_shell
    export PATH="$HOME/.local/bin:$PATH"

    # Install prerequisites
    install_prerequisites

    # Show menu and get choices
    local choices
    choices=$(show_menu)

    # Execute selected tasks
    if has_choice "$choices" "UPDATE"; then
        do_system_update || log ERROR "System update had errors"
    fi

    if has_choice "$choices" "DOCKER"; then
        install_docker || log ERROR "Docker installation failed"
    fi

    if has_choice "$choices" "UV"; then
        install_uv || log ERROR "uv installation failed"
    fi

    if has_choice "$choices" "TOOLS"; then
        install_tools || log ERROR "Tools installation failed"
    fi

    if has_choice "$choices" "ALIAS"; then
        configure_aliases || log ERROR "Alias configuration failed"
    fi

    if has_choice "$choices" "GITHUB"; then
        install_github_cli || log ERROR "GitHub CLI installation failed"
        authenticate_github || log ERROR "GitHub authentication failed"
    fi

    if has_choice "$choices" "CLONE"; then
        clone_repositories || log ERROR "Repository cloning had errors"
    fi

    # Summary
    log_section "Setup Complete!"

    echo ""
    echo "Log file: $LOG_FILE"
    echo ""

    # Provide guidance for next steps
    if [ -t 0 ]; then
        echo -e "${YELLOW}IMPORTANT:${NC} Run 'source ~/.bashrc' or open a new terminal for uv to be available."
        if groups "$USER" | grep -q docker; then
            echo -e "${YELLOW}IMPORTANT:${NC} Log out and back in for docker group to take effect."
        fi
    fi
}

# Run main function
main "$@"
