#!/bin/bash
# WordPress multi-project BACKUP & RESTORE
# - Config: /etc/wp-backup-restore/settings.conf (or ./settings.conf as fallback)
# - Web server: Nginx or Apache2 (config-driven)
# - DB engines: MySQL/MariaDB/PostgreSQL (config-driven; per-project overrides)
# - DATE_DIR = YYYYMMDD
# - Backups: files (tar.gz), vhost, DB (sql.gz)
# - Restore: files + vhost + DB, test & reload web server, restart php-fpm if present
# - Retention: remove backups & logs older than N days

set -Euo pipefail

# --- Require bash 4+ for associative arrays ---
if [[ -z "${BASH_VERSINFO:-}" || ${BASH_VERSINFO[0]} -lt 4 ]]; then
  echo "This script requires bash 4 or newer." >&2
  exit 1
fi

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo (root). Example: sudo $0" >&2
  exit 1
fi

# --- Load config ---
CONFIG_CANDIDATES=( "/etc/wp-backup-restore/settings.conf" "./settings.conf" )
CONFIG_LOADED=""
for C in "${CONFIG_CANDIDATES[@]}"; do
  [[ -f "$C" ]] || continue
  # shellcheck disable=SC1090
  source "$C"
  CONFIG_LOADED="$C"
  break
done
if [[ -z "$CONFIG_LOADED" ]]; then
  echo "Config not found. Create /etc/wp-backup-restore/settings.conf (see example)." >&2
  exit 1
fi

# --- Logging prep ---
mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d%H%M%S)"
DATE_DIR="$(date +%Y%m%d)"
RUN_LOG="${LOG_DIR}/run_${RUN_TS}.log"
touch "$RUN_LOG"
ln -sfn "$RUN_LOG" "${LOG_DIR}/latest.log"
exec > >(tee -a "$RUN_LOG") 2>&1

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "$(ts) [$1] ${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }

info "==== WP Backup/Restore Run Started: ${RUN_TS} ===="
info "Loaded config: ${CONFIG_LOADED}"

# --- Web server helpers ----------------------------------------------------

server_type_norm() {
  case "${SERVER_TYPE,,}" in
    nginx)  echo "nginx" ;;
    apache|apache2|httpd) echo "apache" ;;
    *) echo "nginx" ;;  # default
  esac
}

server_conf_base() {
  local st; st="$(server_type_norm)"
  if [[ "$st" == "nginx" ]]; then
    echo "${SERVER_CONF_BASE_NGINX}"
  else
    echo "${SERVER_CONF_BASE_APACHE}"
  fi
}

detect_web_service() {
  local st; st="$(server_type_norm)"
  if [[ "$st" == "nginx" ]]; then
    echo "nginx.service"; return
  fi
  if systemctl list-unit-files | grep -q "^apache2\.service"; then
    echo "apache2.service"
  elif systemctl list-unit-files | grep -q "^httpd\.service"; then
    echo "httpd.service"
  else
    echo ""
  fi
}

test_server_config() {
  local st; st="$(server_type_norm)"
  if [[ "$st" == "nginx" ]]; then
    nginx -t
  else
    apache2ctl -t 2>&1 || httpd -t
  fi
}

reload_web_server() {
  local svc; svc="$(detect_web_service)"
  if [[ -z "$svc" ]]; then
    warn "Web server service not detected; skipping reload."
    return 0
  fi
  info "Reloading web server: $svc"
  if systemctl reload "$svc"; then
    info "Web server reloaded."
  else
    warn "systemctl reload failed for $svc; trying restart."
    if systemctl restart "$svc"; then
      info "Web server restarted."
    else
      err "Failed to reload/restart $svc. Please handle manually."
      return 1
    fi
  fi
}

# --- Paths & DB helpers ----------------------------------------------------

resolve_path() {
  local base="$1" node="$2"
  if [[ "$node" == /* || -z "$node" ]]; then
    printf '%s\n' "$node"
  else
    printf '%s/%s\n' "$base" "$node"
  fi
}

default_port_for_engine() {
  case "$1" in
    mysql|mariadb) echo "3306" ;;
    postgres)      echo "5432" ;;
    *)             echo "" ;;
  esac
}

get_engine_for_domain() {
  local DOMAIN="$1"
  local eng="${PROJECT_DB_ENGINE[$DOMAIN]:-}"
  [[ -z "$eng" ]] && eng="$DB_ENGINE"
  case "${eng,,}" in
    mysql) echo "mysql" ;;
    mariadb) echo "mariadb" ;;
    postgres|pgsql|postgre) echo "postgres" ;;
    *) echo "mysql" ;;
  esac
}

parse_wp_host_for_mysql() {
  local hostval="$1"
  MYSQL_HOST=""; MYSQL_PORT=""; MYSQL_SOCKET=""
  [[ -z "$hostval" ]] && return 0
  if [[ "$hostval" == *"/"* ]]; then
    if [[ "$hostval" == *":"* ]]; then
      MYSQL_SOCKET="${hostval#*:}"
    else
      MYSQL_SOCKET="$hostval"
    fi
    return 0
  fi
  if [[ "$hostval" == *":"* ]]; then
    MYSQL_HOST="${hostval%%:*}"
    MYSQL_PORT="${hostval##*:}"
  else
    MYSQL_HOST="$hostval"
  fi
}

get_paths_for_domain() {
  local DOMAIN="$1"
  local web="${PROJECT_WEB[$DOMAIN]}"
  local vhost="${PROJECT_VHOST[$DOMAIN]}"
  WEBROOT_PATH="$(resolve_path "$WEBROOT_BASE" "$web")"
  SERVER_CONF_BASE="$(server_conf_base)"
  VHOST_CONF_PATH="$(resolve_path "$SERVER_CONF_BASE" "$vhost")"
  BACKUP_ROOT="${SAVE_BASE}/${DOMAIN}/${DATE_DIR}"
}

get_db_creds() {
  local DOMAIN="$1"
  get_paths_for_domain "$DOMAIN"
  DB_ENGINE_EFF="$(get_engine_for_domain "$DOMAIN")"
  DB_NAME="${PROJECT_DB[$DOMAIN]:-}"
  DB_USER="${PROJECT_DB_USER[$DOMAIN]:-}"
  DB_HOST="${PROJECT_DB_HOST[$DOMAIN]:-}"
  DB_PORT="${PROJECT_DB_PORT[$DOMAIN]:-}"
  MYSQL_SOCKET=""

  local WP_CONFIG="${WEBROOT_PATH}/wp-config.php"
  if [[ "$DB_ENGINE_EFF" == "mysql" || "$DB_ENGINE_EFF" == "mariadb" ]]; then
    if [[ -f "$WP_CONFIG" ]]; then
      [[ -z "${DB_NAME:-}" ]] && DB_NAME="$(grep -E "define\(\s*'DB_NAME'" "$WP_CONFIG" | sed "s/.*'DB_NAME',\s*'\([^']*\)'.*/\1/")" || true
      [[ -z "${DB_USER:-}" ]] && DB_USER="$(grep -E "define\(\s*'DB_USER'" "$WP_CONFIG" | sed "s/.*'DB_USER',\s*'\([^']*\)'.*/\1/")" || true
      if [[ -z "${DB_HOST:-}" ]]; then
        local WP_DB_HOST
        WP_DB_HOST="$(grep -E "define\(\s*'DB_HOST'" "$WP_CONFIG" | sed "s/.*'DB_HOST',\s*'\([^']*\)'.*/\1/")" || true
        parse_wp_host_for_mysql "$WP_DB_HOST"
        [[ -n "$MYSQL_HOST" ]] && DB_HOST="$MYSQL_HOST"
        [[ -n "$MYSQL_PORT" ]] && DB_PORT="$MYSQL_PORT"
      fi
    fi
  fi

  [[ -z "${DB_NAME:-}" ]] && read -rp "[${DOMAIN}] Enter DB name: " DB_NAME
  [[ -z "${DB_USER:-}" ]] && read -rp "[${DOMAIN}] Enter DB user: " DB_USER
  [[ -z "${DB_HOST:-}" ]] && DB_HOST="$DB_HOST_DEFAULT"
  if [[ -z "${DB_PORT:-}" ]]; then
    local dport; dport="$(default_port_for_engine "$DB_ENGINE_EFF")"
    DB_PORT="${DB_PORT_DEFAULT:-$dport}"
  fi

  info "[${DOMAIN}] Engine=${DB_ENGINE_EFF} DB=${DB_NAME} User=${DB_USER} Host=${DB_HOST}${DB_PORT:+ Port=${DB_PORT}}${MYSQL_SOCKET:+ Socket=${MYSQL_SOCKET}}"
}

# --- DB dump/restore -------------------------------------------------------

dump_db() {
  case "$DB_ENGINE_EFF" in
    mysql|mariadb)
      local args=( -u "$DB_USER" -p )
      if [[ -n "$MYSQL_SOCKET" ]]; then
        args+=( --socket="$MYSQL_SOCKET" )
      else
        [[ -n "$DB_HOST" ]] && args+=( -h "$DB_HOST" )
        [[ -n "$DB_PORT" ]] && args+=( -P "$DB_PORT" )
      fi
      mysqldump --add-drop-table "${args[@]}" "$DB_NAME"
      ;;
    postgres)
      local args=( -U "$DB_USER" -W )
      [[ -n "$DB_HOST" ]] && args+=( -h "$DB_HOST" )
      [[ -n "$DB_PORT" ]] && args+=( -p "$DB_PORT" )
      pg_dump --clean --if-exists "${args[@]}" "$DB_NAME"
      ;;
    *) err "Unsupported DB engine: $DB_ENGINE_EFF"; return 1 ;;
  esac
}

restore_db() {
  local dump="$1"
  case "$DB_ENGINE_EFF" in
    mysql|mariadb)
      local args=( -u "$DB_USER" -p )
      if [[ -n "$MYSQL_SOCKET" ]]; then
        args+=( --socket="$MYSQL_SOCKET" )
      else
        [[ -n "$DB_HOST" ]] && args+=( -h "$DB_HOST" )
        [[ -n "$DB_PORT" ]] && args+=( -P "$DB_PORT" )
      fi
      if [[ "$dump" == *.gz ]]; then
        zcat "$dump" | mysql "${args[@]}" "$DB_NAME"
      else
        mysql "${args[@]}" "$DB_NAME" < "$dump"
      fi
      ;;
    postgres)
      local args=( -U "$DB_USER" -W )
      [[ -n "$DB_HOST" ]] && args+=( -h "$DB_HOST" )
      [[ -n "$DB_PORT" ]] && args+=( -p "$DB_PORT" )
      if [[ "$dump" == *.gz ]]; then
        zcat "$dump" | psql "${args[@]}" "$DB_NAME"
      else
        psql "${args[@]}" "$DB_NAME" < "$dump"
      fi
      ;;
    *) err "Unsupported DB engine: $DB_ENGINE_EFF"; return 1 ;;
  esac
}

# --- Retention -------------------------------------------------------------

purge_old_backups() {
  local DOMAIN="$1" DAYS="$2"
  local root="${SAVE_BASE}/${DOMAIN}"
  [[ -d "$root" ]] || return 0
  info "[${DOMAIN}] Purging backups older than ${DAYS} days in ${root} ..."
  find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +"$DAYS" -print -exec rm -rf {} +
}

purge_old_logs() {
  local DAYS="$1"
  [[ -d "$LOG_DIR" ]] || return 0
  info "Purging logs older than ${DAYS} days in ${LOG_DIR} ..."
  find "$LOG_DIR" -type f -name "run_*.log" -mtime +"$DAYS" -print -delete
}

# --- Core ops --------------------------------------------------------------

backup_domain () {
  local DOMAIN="$1"
  get_paths_for_domain "$DOMAIN"
  local TS_DETAIL; TS_DETAIL="$(date +%Y%m%d%H%M%S)"
  local STATUS=0

  info "---- BACKUP ${DOMAIN} ----"
  info "WEBROOT=${WEBROOT_PATH}  VHOST=${VHOST_CONF_PATH}  SAVE=${BACKUP_ROOT}"

  mkdir -p "$BACKUP_ROOT" || { err "Failed to create ${BACKUP_ROOT}"; return 1; }

  get_db_creds "$DOMAIN" || STATUS=1

  # 1) Files
  if [[ -d "$WEBROOT_PATH" ]]; then
    info "[${DOMAIN}] Archiving files..."
    if tar czf "${BACKUP_ROOT}/${TS_DETAIL}_files.tar.gz" -C "$(dirname "$WEBROOT_PATH")" "$(basename "$WEBROOT_PATH")"; then
      info "[${DOMAIN}] Files -> ${BACKUP_ROOT}/${TS_DETAIL}_files.tar.gz"
    else
      err  "[${DOMAIN}] Files archive FAILED"
      STATUS=1
    fi
  else
    warn "[${DOMAIN}] Webroot not found at ${WEBROOT_PATH} (skipping files)"
    STATUS=1
  fi

  # 2) Vhost
  if [[ -f "$VHOST_CONF_PATH" ]]; then
    if cp "$VHOST_CONF_PATH" "$BACKUP_ROOT/"; then
      info "[${DOMAIN}] Vhost -> ${BACKUP_ROOT}/$(basename "$VHOST_CONF_PATH")"
    else
      err  "[${DOMAIN}] Vhost copy FAILED"
      STATUS=1
    fi
  else
    warn "[${DOMAIN}] Vhost not found at ${VHOST_CONF_PATH} (skipping)"
  fi

  # 3) DB
  info "[${DOMAIN}] Dumping DB (you will be prompted for password)..."
  set -o pipefail
  if dump_db | gzip > "${BACKUP_ROOT}/db_${TS_DETAIL}.sql.gz"; then
    info "[${DOMAIN}] DB -> ${BACKUP_ROOT}/db_${TS_DETAIL}.sql.gz"
  else
    err  "[${DOMAIN}] DB dump FAILED"
    STATUS=1
  fi
  set +o pipefail

  # 4) Retention
  purge_old_backups "$DOMAIN" "$BACKUP_RETENTION_DAYS"

  if [[ $STATUS -eq 0 ]]; then
    info "---- BACKUP completed for ${DOMAIN} ✅ ----"
  else
    err  "---- BACKUP completed with errors for ${DOMAIN} ❌ ----"
  fi
  return $STATUS
}

list_versions() {
  local DOMAIN="$1"
  local root="${SAVE_BASE}/${DOMAIN}"

  V_TS=() V_DB=() V_FILES=() V_DIR=()

  if [[ ! -d "$root" ]]; then
    warn "[${DOMAIN}] No backups found under ${root}"
    return 1
  fi

  mapfile -t DB_FILES < <(find "$root" -type f -name "db_*.sql.gz" | sort -r)
  if [[ ${#DB_FILES[@]} -eq 0 ]]; then
    warn "[${DOMAIN}] No DB dumps found."
    return 1
  fi

  for db in "${DB_FILES[@]}"; do
    local dir ts files_tar
    dir="$(dirname "$db")"
    ts="$(basename "$db" | sed -n "s/^db_\([0-9]\{14\}\)\.sql\.gz$/\1/p")"
    [[ -z "$ts" ]] && continue
    files_tar="${dir}/${ts}_files.tar.gz"
    [[ -f "$files_tar" ]] || continue

    V_TS+=("$ts"); V_DB+=("$db"); V_FILES+=("$files_tar"); V_DIR+=("$dir")
  done

  if [[ ${#V_TS[@]} -eq 0 ]]; then
    warn "[${DOMAIN}] No complete (files+DB) versions found."
    return 1
  fi

  echo
  echo "Available versions for ${DOMAIN}:"
  local i
  for i in "${!V_TS[@]}"; do
    local human
    if human="$(date -d "${V_TS[$i]}" +'%Y-%m-%d %H:%M:%S' 2>/dev/null)"; then
      printf "%2d) %s  (dir: %s)\n" "$((i+1))" "$human [${V_TS[$i]}]" "$(basename "${V_DIR[$i]}")"
    else
      printf "%2d) %s  (dir: %s)\n" "$((i+1))" "${V_TS[$i]}" "$(basename "${V_DIR[$i]}")"
    fi
  done
}

restore_domain () {
  local DOMAIN="$1"
  get_paths_for_domain "$DOMAIN"
  info "---- RESTORE ${DOMAIN} ----"

  get_db_creds "$DOMAIN" || return 1

  if ! list_versions "$DOMAIN"; then
    err "[${DOMAIN}] No restorable versions."
    return 1
  fi

  local choice idx
  read -rp "Select version number to restore [1-${#V_TS[@]}]: " choice
  idx=$((choice-1))
  if [[ -z "${choice:-}" || $idx -lt 0 || $idx -ge ${#V_TS[@]} ]]; then
    err "Invalid selection."
    return 1
  fi

  local SEL_TS="${V_TS[$idx]}"
  local DB_DUMP="${V_DB[$idx]}"
  local FILES_TAR="${V_FILES[$idx]}"
  local BACKUP_DIR="${V_DIR[$idx]}"
  local VHOST_BAK="${BACKUP_DIR}/$(basename "$VHOST_CONF_PATH")"

  echo
  warn "You are about to RESTORE ${DOMAIN} to version ${SEL_TS}."
  warn "This will overwrite site files and database: ${DB_NAME}"
  read -rp "Type 'RESTORE' to proceed: " CONFIRM
  [[ "$CONFIRM" == "RESTORE" ]] || { info "Restore cancelled."; return 1; }

  # Pre-restore snapshot
  info "[${DOMAIN}] Creating pre-restore BACKUP snapshot..."
  if ! backup_domain "$DOMAIN"; then
    warn "[${DOMAIN}] Pre-restore backup had issues (continuing)."
  fi

  # 1) Files
  if [[ -f "$FILES_TAR" ]]; then
    info "[${DOMAIN}] Restoring files from ${FILES_TAR} ..."
    if tar xzf "$FILES_TAR" -C "$(dirname "$WEBROOT_PATH")"; then
      info "[${DOMAIN}] Files restored."
      if id -u www-data >/dev/null 2>&1; then
        chown -R "$WEB_OWNERSHIP" "$WEBROOT_PATH" || warn "[${DOMAIN}] chown failed; check ownership."
      fi
    else
      err "[${DOMAIN}] File restore FAILED."
      return 1
    fi
  else
    err "[${DOMAIN}] Missing files archive: ${FILES_TAR}"
    return 1
  fi

  # 2) Vhost (Nginx or Apache, based on config)
  if [[ -f "$VHOST_BAK" ]]; then
    info "[${DOMAIN}] Restoring vhost/site config..."
    if cp "$VHOST_BAK" "$VHOST_CONF_PATH"; then
      info "[${DOMAIN}] Vhost restored to ${VHOST_CONF_PATH}"
      if test_server_config; then
        read -rp "Reload web server now? [Y/n]: " RELOAD_WS
        RELOAD_WS="${RELOAD_WS:-Y}"
        [[ "$RELOAD_WS" =~ ^[Yy]$ ]] && reload_web_server || info "Skipped web server reload."
      else
        err "[${DOMAIN}] Server config test FAILED — not reloading."
      fi
    else
      warn "[${DOMAIN}] Failed to copy vhost backup (skipping)."
    fi
  else
    warn "[${DOMAIN}] No vhost backup found at ${VHOST_BAK} (skipping)."
  fi

  # 3) DB
  if [[ -f "$DB_DUMP" ]]; then
    info "[${DOMAIN}] Restoring DB from ${DB_DUMP} (you will be prompted for password)..."
    set -o pipefail
    if restore_db "$DB_DUMP"; then
      info "[${DOMAIN}] Database restored."
    else
      err "[${DOMAIN}] Database restore FAILED."
      set +o pipefail
      return 1
    fi
    set +o pipefail
  else
    err "[${DOMAIN}] Missing DB dump: ${DB_DUMP}"
    return 1
  fi

  # 4) Restart php-fpm (if present)
  detect_php_fpm() {
    systemctl list-units --type=service --state=running | awk '/php.*-fpm\.service/ {print $1; exit}'
  }
  PHPFPM_SVC="$(detect_php_fpm || true)"
  if [[ -n "${PHPFPM_SVC:-}" ]]; then
    info "Restarting php-fpm: $PHPFPM_SVC"
    systemctl restart "$PHPFPM_SVC" || warn "php-fpm restart failed; check manually."
  else
    info "No php-fpm service detected; skipping."
  fi

  info "---- RESTORE completed for ${DOMAIN} ✅ ----"
}

# --- Menus -----------------------------------------------------------------

echo
echo "What would you like to do?"
echo "1) Perform a backup (default)"
echo "2) Restore a specific version"
echo "3) Both: backup then restore"
read -rp "Enter choice [1-3, default 1]: " ACT_CHOICE
ACT_CHOICE="${ACT_CHOICE:-1}"

# Backup selection (if applicable)
DOMAINS=()
if [[ "$ACT_CHOICE" == "1" || "$ACT_CHOICE" == "3" ]]; then
  echo
  echo "Select what to back up:"
  echo "1) ALL projects (default)"
  i=2
  for d in "${PROJECTS[@]}"; do
    echo "${i}) ${d}"
    ((i++))
  done
  read -rp "Enter choice [1-$(( ${#PROJECTS[@]} + 1 )) , default 1]: " CHOICE
  CHOICE="${CHOICE:-1}"

  if [[ "$CHOICE" == "1" ]]; then
    DOMAINS=("${PROJECTS[@]}")
  else
    index=$((CHOICE - 2))  # because 1 = All
    if [[ $index -lt 0 || $index -ge ${#PROJECTS[@]} ]]; then
      err "Invalid backup choice."
      exit 1
    fi
    DOMAINS=("${PROJECTS[$index]}")
  fi

  info "Selected for BACKUP: ${DOMAINS[*]}"
  FAILED_B=()
  for d in "${DOMAINS[@]}"; do
    if ! backup_domain "$d"; then
      FAILED_B+=("$d")
    fi
  done
  if [[ ${#FAILED_B[@]} -gt 0 ]]; then
    err "Backup failures: ${FAILED_B[*]}"
  else
    info "Backups completed successfully."
  fi
fi

# Restore selection (if applicable)
if [[ "$ACT_CHOICE" == "2" || "$ACT_CHOICE" == "3" ]]; then
  echo
  echo "Select a project to RESTORE (one domain at a time):"
  i=1
  for d in "${PROJECTS[@]}"; do
    echo "${i}) ${d}"
    ((i++))
  done
  read -rp "Enter choice [1-${#PROJECTS[@]}]: " RCHOICE
  rindex=$((RCHOICE - 1))
  if [[ -z "${RCHOICE:-}" || $rindex -lt 0 || $rindex -ge ${#PROJECTS[@]} ]]; then
    err "Invalid restore choice."
    exit 1
  fi
  RESTORE_DOMAIN="${PROJECTS[$rindex]}"

  if ! restore_domain "$RESTORE_DOMAIN"; then
    err "Restore failed for ${RESTORE_DOMAIN}"
    exit 1
  fi
fi

# --- Log rotation (always) ---
purge_old_logs "$LOG_RETENTION_DAYS"

echo
info "==== Run finished. Log: ${RUN_LOG} | Latest: ${LOG_DIR}/latest.log ===="
