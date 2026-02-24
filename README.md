# Personal Setup CLI

Interactive setup script for Ubuntu: system update, Docker, uv, GitHub CLI, and repo cloning.

## Quick Run

**Cloudflare Pages (recommended):**

```bash
curl -sSf https://setup.domain.com/ | bash
```

Replace `setup.domain.com` with your custom domain after deploying to Cloudflare Pages.

**Raw GitHub URL:**

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
- `sudo` access (you'll be prompted when needed)
- Internet connection

**Do not run with sudo** — run as your normal user. The script will ask for your password only when installing packages.

The script will install `whiptail` and `fzf` if missing.

## Deploy to Cloudflare Pages

1. Push this repo to GitHub.
2. In [Cloudflare Dashboard](https://dash.cloudflare.com) → **Pages** → **Create project** → **Connect to Git**.
3. Select your repo and configure:
   - **Framework preset:** None
   - **Build command:** (leave empty)
   - **Output directory:** `/` (root)
4. Add a custom domain: **Pages** → your project → **Custom domains** → add `setup.domain.com`.
5. Your script will be available at:
   - `https://setup.domain.com/` (root serves the script via `_redirects`)
   - `https://setup.domain.com/setup.sh`
