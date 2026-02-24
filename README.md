# Personal Setup CLI

Interactive setup script for Ubuntu: system update, Docker, uv, GitHub CLI, and repo cloning.

## Quick Run (from raw GitHub URL)

```bash
curl -fsSL https://raw.githubusercontent.com/jeep-jeg-viss/pcli/main/setup.sh | bash
```

> If your default branch is `master`, use that instead of `main`.

**Note:** When run this way, the script uses your current directory. Create a `config.env` in that directory first if you want custom repos or a token (see [Configuration](#configuration)).

## Recommended: Clone and Run

For full control (config, updates):

```bash
git clone https://github.com/jeep-jeg-viss/pcli.git
cd pcli
cp config.env.example config.env   # optional: edit with your repos/token
./setup.sh
```

## Configuration

Copy `config.env.example` to `config.env` and edit:

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | Optional. If unset, you'll be prompted to run `gh auth login` |
| `TARGET_DIR` | Where to clone repos (default: `~/code`) |
| `REPOS` | Array of repo URLs for config-based selection |

## Requirements

- Ubuntu (or Debian-based)
- `sudo` access
- Internet connection

The script will install `whiptail` and `fzf` if missing.
