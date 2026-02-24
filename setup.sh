#!/bin/bash
set -e

# ==========================================
# 0. CONFIGURATION & PRE-FLIGHT
# ==========================================

# Load config
if [ -f "config.env" ]; then
    source config.env
fi

# Ensure common tool paths (uv, etc.) are available
export PATH="$HOME/.local/bin:$PATH"

# Function to check if a command exists
exists() {
    command -v "$1" >/dev/null 2>&1
}

# Ensure whiptail (for menu) and fzf (for repo selection) are installed
if ! exists whiptail || ! exists fzf; then
    echo "Installing interface tools (whiptail, fzf)..."
    sudo apt-get update && sudo apt-get install -y whiptail fzf
fi

# ==========================================
# 1. MAIN MENU
# ==========================================

CHOICES=$(whiptail --title "Personal Setup" --checklist \
"Select tasks:" 20 78 12 \
"UPDATE" "System Update (apt update/upgrade)" ON \
"DOCKER" "Docker Engine & Compose" ON \
"UV" "uv (Python Tool)" ON \
"TOOLS" "XVFB, Vim, Common Utils" ON \
"ALIAS" "Alias nano to vim" OFF \
"GITHUB" "GitHub CLI (gh) + Auth" ON \
"CLONE" "Clone Repositories (Interactive)" ON \
3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then echo "Cancelled."; exit 0; fi

has_choice() { [[ "$CHOICES" == *"$1"* ]]; }

# ==========================================
# 2. INSTALLATION TASKS
# ==========================================

if has_choice "UPDATE"; then
    echo "--- Updating System ---"
    sudo apt-get update -y && sudo apt-get upgrade -y
    sudo apt-get install -y curl wget gpg coreutils build-essential git
fi

if has_choice "DOCKER"; then
    if ! exists docker; then
        echo "--- Installing Docker ---"
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker "$USER"
        echo "Note: You may need to log out and back in for docker group to take effect."
    fi
fi

if has_choice "UV"; then
    if ! exists uv; then
        echo "--- Installing uv ---"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

if has_choice "TOOLS"; then
    echo "--- Installing XVFB & Vim ---"
    sudo apt-get install -y xvfb vim
fi

if has_choice "ALIAS"; then
    RC="$HOME/.bashrc"
    if ! grep -q "alias nano='vim'" "$RC"; then
        echo "alias nano='vim'" >> "$RC"
        echo "export EDITOR='vim'" >> "$RC"
        echo "Alias added."
    fi
fi

# ==========================================
# 3. GITHUB AUTH
# ==========================================

if has_choice "GITHUB"; then
    if ! exists gh; then
        echo "--- Installing GitHub CLI ---"
        # Standard GH install steps...
        sudo mkdir -p -m 755 /etc/apt/keyrings && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y gh
    fi

    echo "--- Authenticating GitHub ---"
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "$GITHUB_TOKEN" | gh auth login --with-token
        echo "Success."
    elif gh auth status &>/dev/null; then
        echo "Already authenticated."
    else
        echo "GitHub CLI is not authenticated. Running interactive login..."
        gh auth login
    fi
fi

# ==========================================
# 4. REPO SELECTION (The Upgrade)
# ==========================================

if has_choice "CLONE"; then
    echo "--- Repository Selection ---"
    
    # 1. Ask for Source
    SOURCE=$(whiptail --title "Repo Source" --menu "Where should we get repos from?" 15 60 3 \
    "1" "Config file only (config.env)" \
    "2" "GitHub API only (Fetch all my repos)" \
    "3" "Both (Merge lists)" 3>&1 1>&2 2>&3)

    if [ -z "$SOURCE" ]; then echo "Cancelled."; exit 0; fi

    ALL_URLS=""

    # Get Config Repos
    if [ "$SOURCE" == "1" ] || [ "$SOURCE" == "3" ]; then
        if [ -n "${REPOS+x}" ]; then
            for r in "${REPOS[@]}"; do
                ALL_URLS+="$r"$'\n'
            done
        else
            echo "Warning: REPOS not defined in config.env. Add REPOS=(url1 url2) for config-based repos."
        fi
    fi

    # Get API Repos (requires gh auth)
    if [ "$SOURCE" == "2" ] || [ "$SOURCE" == "3" ]; then
        if ! exists gh; then
            echo "Error: GitHub CLI (gh) is required for this option. Run setup again and select 'GitHub CLI (gh) + Auth' first."
            exit 1
        fi
        if ! gh auth status &>/dev/null; then
            echo "GitHub CLI must be authenticated to fetch repos. Running interactive login..."
            gh auth login
        fi
        echo "Fetching repos from GitHub (this may take a second)..."
        # Fetches HTTPS URLs of all repos you have access to
        API_URLS=$(gh repo list --limit 500 --json url --jq '.[].url')
        ALL_URLS+="$API_URLS"$'\n'
    fi

    # 2. Interactive Selection using FZF
    # -m allows multi-select (TAB to select)
    # --height makes it look like a popup
    echo "Opening Selector... (Use TAB to select multiple, ENTER to confirm)"
    SELECTED_REPOS=$(echo "$ALL_URLS" | grep -v "^$" | sort | uniq | fzf -m --height=40% --layout=reverse --border --prompt="Select Repos to Clone > ")

    if [ -z "$SELECTED_REPOS" ]; then
        echo "No repos selected."
    else
        # 3. Setup Target Dir
        if [ -z "$TARGET_DIR" ]; then TARGET_DIR="$HOME/code"; fi
        mkdir -p "$TARGET_DIR"
        
        echo "--- Cloning to $TARGET_DIR ---"
        while IFS= read -r repo_url; do
            repo_name=$(basename "$repo_url" .git)
            if [ -d "$TARGET_DIR/$repo_name" ]; then
                echo "Skipping $repo_name (exists)"
            else
                echo "Cloning $repo_name..."
                git clone "$repo_url" "$TARGET_DIR/$repo_name"
            fi
        done <<< "$SELECTED_REPOS"
    fi
fi

echo "--- Setup Complete! ---"