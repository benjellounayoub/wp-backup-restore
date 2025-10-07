# WordPress Multi‑Site Backup & Restore

A single Bash tool to **backup and restore multiple WordPress projects** on one server.

- **Script:** `/etc/wp-backup-restore/script.sh`
- **Config:** `/etc/wp-backup-restore/settings.conf`
- **Supports:** Nginx **or** Apache · MariaDB/MySQL **or** PostgreSQL
- **Backups:** site files (`.tar.gz`) + vhost file + DB dump (`.sql.gz`)
- **Restore:** files + vhost + DB, then (optionally) reload web server and restart php-fpm
- **Retention:** auto-prune old backups & logs
- **Logging:** `/var/log/wp-backup-restore/` (with `latest.log` symlink)

---

## Requirements

- Linux with Bash **4+** (Ubuntu/Debian/Rocky/Alma/CentOS etc.)
- Root privileges to run (`sudo`)
- DB client tools installed as needed:
  - MariaDB/MySQL: `mysql`, `mysqldump`
  - PostgreSQL: `psql`, `pg_dump`
- Web server: **Nginx** or **Apache 2.4+**

> The script prompts for DB passwords securely (no plaintext in command line).

---

## Install

1) Create the directory and place files

```bash
sudo mkdir -p /etc/wp-backup-restore
# put script.sh and settings.conf in this folder
# (or move them if you already have them elsewhere)
sudo mv script.sh /etc/wp-backup-restore/ 2>/dev/null || true
sudo mv settings.conf /etc/wp-backup-restore/ 2>/dev/null || true
```

2) Make the script executable

```bash
sudo chmod +x /etc/wp-backup-restore/script.sh
```

3) (Optional) Add to PATH for convenience

```bash
echo 'alias wpbr="/etc/wp-backup-restore/script.sh"' | sudo tee /etc/profile.d/wpbr.sh >/dev/null
source /etc/profile.d/wpbr.sh
```

Run it:

```bash
sudo /etc/wp-backup-restore/script.sh
# or, if you added the alias:
sudo wpbr
```

---

## Configure (`/etc/wp-backup-restore/settings.conf`)

Key fields (defaults shown):

```bash
# Global paths
WEBROOT_BASE="/var/www/html"
SAVE_BASE="/var/www/backup"
LOG_DIR="/var/log/wp-backup-restore"
WEB_OWNERSHIP="www-data:www-data"

# Web server: nginx | apache
SERVER_TYPE="nginx"
SERVER_CONF_BASE_NGINX="/etc/nginx/sites-available"
SERVER_CONF_BASE_APACHE="/etc/apache2/sites-available"

# Retention (days)
BACKUP_RETENTION_DAYS=30
LOG_RETENTION_DAYS=30

# Default DB engine for projects: mysql | mariadb | postgres
DB_ENGINE="mysql"
DB_HOST_DEFAULT="localhost"
DB_PORT_DEFAULT=""   # empty = engine default (3306/5432)

# Project registry
PROJECTS=( "domain1.com" "domain2.com" "domain3.com" "domain4.com" "domain5.com" "domain6.com" )

# Mappings (values can be absolute paths or relative to *_BASE)
declare -A PROJECT_WEB=(
  [domain1.com]="domain1.com"
  # ...
)
declare -A PROJECT_VHOST=(
  [domain1.com]="domain1.com"        # Apache usually needs .conf (e.g. domain1.com.conf)
  # ...
)

# Optional per‑project DB overrides (empty = auto-detect from wp-config.php for MySQL/MariaDB)
declare -A PROJECT_DB_ENGINE=( [domain1.com]="" )
declare -A PROJECT_DB=( [domain1.com]="" )
declare -A PROJECT_DB_USER=( [domain1.com]="" )
declare -A PROJECT_DB_HOST=( [domain1.com]="" )
declare -A PROJECT_DB_PORT=( [domain1.com]="" )
```

Tips:

- For **Apache**, `PROJECT_VHOST[example.com]` often ends with `.conf` (e.g. `example.com.conf`).
- If a mapping starts with `/`, it is treated as an **absolute path**.
- For MySQL/MariaDB, DB name/user are auto-detected from each site’s `wp-config.php` when not provided.
- For PostgreSQL projects, set `PROJECT_DB_ENGINE[domain]="postgres"` and provide DB name/user if not discoverable.

---

## What gets backed up

For each project and each run (date folder `YYYYMMDD`):

```
/var/www/backup/<domain>/<YYYYMMDD>/
├── <timestamp>_files.tar.gz        # Site files (WordPress root for that site)
├── db_<timestamp>.sql.gz           # Database dump
└── <vhost_filename>                # Nginx/Apache vhost file
```

`<timestamp>` is `YYYYMMDDHHMMSS` (per run), and multiple backups may exist per day.

---

## How to use

Run the script:

```bash
sudo /etc/wp-backup-restore/script.sh
```

You’ll see a menu:

```
What would you like to do?
1) Perform a backup (default)
2) Restore a specific version
3) Both: backup then restore
```

### Backup
- Choose **ALL** projects (default) or a specific one.
- The script compresses files, dumps the DB, and copies the vhost file.
- Old backups are pruned automatically (per `BACKUP_RETENTION_DAYS`).

### Restore
- Choose a project; select a **version** from the list.
- Confirm by typing `RESTORE` (safety).
- The script creates a **pre‑restore snapshot**, restores files + vhost + DB,
  then tests and optionally reloads the web server.
- Finally, it restarts `php-fpm` when present.

---

## Logs & Retention

- Run logs: `/var/log/wp-backup-restore/run_<timestamp>.log`
- Convenience symlink: `/var/log/wp-backup-restore/latest.log`
- Old logs are pruned per `LOG_RETENTION_DAYS`.

Check the latest run:

```bash
sudo tail -f /var/log/wp-backup-restore/latest.log
```

---

## Cron (optional)

Nightly backup of **ALL** projects at 2:00 AM:

```bash
sudo crontab -e
```

Add:

```cron
0 2 * * * /etc/wp-backup-restore/script.sh >/dev/null 2>&1
```

> Ensure your `settings.conf` has the correct project list and mappings before enabling cron.

---

## Troubleshooting

| Issue | Hint                                                                                                           |
|------|----------------------------------------------------------------------------------------------------------------|
| `Permission denied` | Run with `sudo`. Ensure `/var/www/backup` is writable.                                                         |
| Nginx/Apache reload fails | Run `nginx -t` or `apache2ctl -t` to validate config; fix and retry.                                           |
| MySQL/MariaDB prompts every time | That’s expected for secure password input (`-p`). Consider using `.my.cnf` with proper permissions if desired. |
| PostgreSQL auth errors | Ensure the DB user has rights; check `pg_hba.conf`. Use `psql -U user -h host -p port dbname`.                 |
| Wrong vhost file backed up | Verify `PROJECT_VHOST[domain]` and `SERVER_TYPE`. For Apache, include `.conf` if used by your distro.          |
| Auto-detect DB failed | Fill `PROJECT_DB[domain]` and `PROJECT_DB_USER[domain]` explicitly.                                            |

---

## Security Notes

- Backups may contain **sensitive data** (wp-config, uploads). Limit access to `/var/www/backup` and `/var/log/wp-backup-restore`.
- Consider off‑site syncing (e.g., rsync to another server or cloud storage).
- Keep DB credentials out of shell history; the script prompts interactively.

---

## License

MIT — do what you want, just don’t hold the authors liable.

---

## Credits

Maintained by **Mohamed‑Ayoub Benjelloun**. Contributions welcome.
