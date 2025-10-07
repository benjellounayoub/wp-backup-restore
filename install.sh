#!/usr/bin/env bash
# install.sh — Installer for wp-backup-restore
# - Clones (or updates) the repo to /opt/wp-backup-restore
# - Installs config to /etc/wp-backup-restore/settings.conf (does NOT overwrite existing)
# - Creates logs dir /var/log/wp-backup-restore and backups dir /var/www/backup
# - Symlinks /usr/local/bin/wpbr -> /opt/wp-backup-restore/script.sh
# - Leaves your settings.conf intact on re-runs (idempotent)
# - Usage:
#     sudo bash install.sh                 # fresh install (clone if needed)
#     sudo bash install.sh --update        # pull latest changes
#     sudo bash install.sh --https         # use HTTPS instead of SSH for cloning
#     sudo bash install.sh --branch main   # choose branch (default: main)
#     sudo bash install.sh --no-clone      # skip cloning (files already present in cwd)
#     sudo bash install.sh --force-link    # recreate /usr/local/bin/wpbr symlink
#
set -euo pipefail

REPO_SSH="git@github.com:benjellounayoub/wp-backup-restore.git"
REPO_HTTPS="https://github.com/benjellounayoub/wp-backup-restore.git"
BRANCH="main"
USE_HTTPS=0
DO_UPDATE=0
SKIP_CLONE=0
FORCE_LINK=0

INSTALL_DIR="/opt/wp-backup-restore"
ETC_DIR="/etc/wp-backup-restore"
BIN_TARGET="/usr/local/bin/wpbr"
LOG_DIR="/var/log/wp-backup-restore"
BACKUP_DIR="/var/www/backup"

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --https) USE_HTTPS=1; shift ;;
    --branch) BRANCH="${2:-main}"; shift 2 ;;
    --update) DO_UPDATE=1; shift ;;
    --no-clone) SKIP_CLONE=1; shift ;;
    --force-link) FORCE_LINK=1; shift ;;
    -h|--help)
      sed -n '1,35p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- logging helpers ---
ts(){ date '+%Y-%m-%dT%H:%M:%S%z'; }
log(){ echo "$(ts) [$1] ${*:2}"; }
info(){ log INFO "$@"; }
warn(){ log WARN "$@"; }
err(){ log ERROR "$@"; }

# --- require root ---
if [[ $EUID -ne 0 ]]; then
  err "Please run as root (sudo)."
  exit 1
fi

# --- dependency checks (soft for DB tools) ---
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; return 1; }; }
soft_check(){ command -v "$1" >/dev/null 2>&1 || warn "Optional tool not found: $1"; }

need_cmd git
need_cmd tar
need_cmd gzip
need_cmd ln
soft_check mysql
soft_check mysqldump
soft_check psql
soft_check pg_dump

# --- clone or update repo into /opt ---
mkdir -p "$(dirname "$INSTALL_DIR")"
if [[ $SKIP_CLONE -eq 1 ]]; then
  info "Skipping clone; using current working directory as source."
  SRC_DIR="$PWD"
else
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Repository already present at $INSTALL_DIR"
    if [[ $DO_UPDATE -eq 1 ]]; then
      info "Updating repository (git pull)..."
      git -C "$INSTALL_DIR" fetch --all --prune
      git -C "$INSTALL_DIR" checkout "$BRANCH"
      git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
    else
      info "Use --update to pull latest changes."
    fi
  else
    REPO_URL="$REPO_SSH"
    if [[ $USE_HTTPS -eq 1 ]]; then REPO_URL="$REPO_HTTPS"; fi
    info "Cloning $REPO_URL to $INSTALL_DIR (branch: $BRANCH)"
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
  SRC_DIR="$INSTALL_DIR"
fi

# --- verify required files ---
if [[ ! -f "$SRC_DIR/script.sh" ]]; then
  err "script.sh not found in $SRC_DIR"
  exit 1
fi

# settings.conf may be absent in repo; we'll generate a template if needed
TEMPLATE_CONF=""
if [[ -f "$SRC_DIR/settings.conf" ]]; then
  TEMPLATE_CONF="$SRC_DIR/settings.conf"
fi

# --- install script (in /opt) ---
if [[ "$SRC_DIR" != "$INSTALL_DIR" ]]; then
  info "Copying script to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  cp -f "$SRC_DIR/script.sh" "$INSTALL_DIR/"
fi
chmod +x "$INSTALL_DIR/script.sh"

# --- install config (in /etc), without overwriting ---
mkdir -p "$ETC_DIR"
if [[ -f "$ETC_DIR/settings.conf" ]]; then
  info "Config already exists at $ETC_DIR/settings.conf (leaving as-is)."
else
  if [[ -n "$TEMPLATE_CONF" ]]; then
    info "Installing config from repository template."
    cp "$TEMPLATE_CONF" "$ETC_DIR/settings.conf"
  else
    info "Creating default settings.conf template."
    cat > "$ETC_DIR/settings.conf" <<'CONF'
# /etc/wp-backup-restore/settings.conf
WEBROOT_BASE="/var/www/html"
SAVE_BASE="/var/www/backup"
LOG_DIR="/var/log/wp-backup-restore"
WEB_OWNERSHIP="www-data:www-data"

SERVER_TYPE="nginx"
SERVER_CONF_BASE_NGINX="/etc/nginx/sites-available"
SERVER_CONF_BASE_APACHE="/etc/apache2/sites-available"

BACKUP_RETENTION_DAYS=30
LOG_RETENTION_DAYS=30

DB_ENGINE="mysql"
DB_HOST_DEFAULT="localhost"
DB_PORT_DEFAULT=""

PROJECTS=( "example.com" )

declare -A PROJECT_WEB=( [example.com]="example.com" )
declare -A PROJECT_VHOST=( [example.com]="example.com" )

declare -A PROJECT_DB_ENGINE=( [example.com]="" )
declare -A PROJECT_DB=( [example.com]="" )
declare -A PROJECT_DB_USER=( [example.com]="" )
declare -A PROJECT_DB_HOST=( [example.com]="" )
declare -A PROJECT_DB_PORT=( [example.com]="" )
CONF
  fi
fi

# --- create runtime directories ---
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"
chmod 750 "$LOG_DIR" || true
chmod 750 "$BACKUP_DIR" || true

# --- symlink executable ---
if [[ -L "$BIN_TARGET" || -e "$BIN_TARGET" ]]; then
  if [[ $FORCE_LINK -eq 1 ]]; then
    info "Recreating symlink $BIN_TARGET"
    rm -f "$BIN_TARGET"
    ln -s "$INSTALL_DIR/script.sh" "$BIN_TARGET"
  else
    info "$BIN_TARGET already exists. Use --force-link to recreate."
  fi
else
  info "Creating symlink $BIN_TARGET -> $INSTALL_DIR/script.sh"
  ln -s "$INSTALL_DIR/script.sh" "$BIN_TARGET"
fi

# --- summary ---
cat <<SUM

✅ Installation complete!

• Script:      $INSTALL_DIR/script.sh
• Config:      $ETC_DIR/settings.conf
• Logs:        $LOG_DIR
• Backups:     $BACKUP_DIR
• Shortcut:    $BIN_TARGET

Next steps:
  1) Edit your projects in: sudo nano $ETC_DIR/settings.conf
  2) Run the tool:          sudo wpbr
  3) (Optional) Cron job:   sudo crontab -e
     0 2 * * * $INSTALL_DIR/script.sh >/dev/null 2>&1

Tips:
  • Re-run this installer with --update to pull new versions.
  • Use --https if your server doesn't have SSH access to GitHub.
  • Your existing settings.conf is preserved on re-install.

SUM
