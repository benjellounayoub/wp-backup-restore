# WordPress Multi‑Site Backup & Restore

Easily back up and restore multiple WordPress sites hosted on the same server.

---

## 🧩 Features

- **Supports:** Nginx **or** Apache · MariaDB **or** MySQL **or** PostgreSQL  
- **Backups:** site files (`.tar.gz`) + vhost config + database dump (`.sql.gz`)  
- **Restore:** full or partial restore with confirmation prompts  
- **Retention:** auto-prune old backups and logs  
- **Logging:** `/var/log/wp-backup-restore/` (with `latest.log` symlink)  
- **Multi-project aware:** can back up or restore all or a single site interactively  
- **Safe:** pre‑restore backup snapshot before overwriting data  

---

## ⚙️ Requirements

- Linux with Bash **4+**
- Root privileges (`sudo`)
- DB client tools installed as needed:
  - MariaDB/MySQL: `mysql`, `mysqldump`
  - PostgreSQL: `psql`, `pg_dump`
- Web server: **Nginx** or **Apache 2.4+**

> The script prompts for DB passwords securely (no plaintext in command line).

---

## 📦 Quick Installation

The project includes an **install script** that automates setup for you.

### 1️⃣ Clone and install

```bash
cd /tmp
git clone https://github.com/benjellounayoub/wp-backup-restore.git
cd wp-backup-restore
sudo bash install.sh --https --branch master
```

This will:
- Clone the project into `/opt/wp-backup-restore`
- Install the configuration in `/etc/wp-backup-restore/settings.conf`
- Create log and backup directories:
  - `/var/log/wp-backup-restore/`
  - `/var/www/backup/`
- Create a global shortcut `wpbr` linked to `/opt/wp-backup-restore/script.sh`

Optional flags (for advanced use only, please skip otherwise):
```bash
sudo bash install.sh --update        # Pull latest changes
sudo bash install.sh --https         # Use HTTPS for cloning
sudo bash install.sh --branch dev    # Clone specific branch
sudo bash install.sh --no-clone      # Skip cloning (use local files)
sudo bash install.sh --force-link    # Recreate /usr/local/bin/wpbr symlink
```

## 2️⃣ Adapt settings.conf to your environment (`/etc/wp-backup-restore/settings.conf`)

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
PROJECTS=( 
  "domain1.com" 
  "domain2.com" 
  "domain3.com"
  ... 
)

# Mappings (values can be absolute paths or relative to *_BASE)
declare -A PROJECT_WEB=(
  [domain1.com]="domain1.com"
  [domain2.com]="domain2.com"
  [domain3.com]="domain3.com"
  ...
)
declare -A PROJECT_VHOST=(
  [domain1.com]="domain1.com.conf"        # Apache usually needs .conf (e.g. domain1.com.conf)
  [domain2.com]="domain2.com.conf" 
  [domain3.com]="domain3.com.conf" 
  ...
)

# Optional per‑project DB overrides (empty = auto-detect from wp-config.php for MySQL/MariaDB)
declare -A PROJECT_DB_ENGINE=( [domain1.com]="mysql" )
declare -A PROJECT_DB=( [domain1.com]="DOMAIN1_DB_NAME" )
declare -A PROJECT_DB_USER=( [domain1.com]="DOMAIN1_DB_USER" )
declare -A PROJECT_DB_HOST=( [domain1.com]="DOMAIN1_DB_HOST" )
declare -A PROJECT_DB_PORT=( [domain1.com]="DOMAIN1_DB_PORT" )
```

Tips:

- For **Apache**, `PROJECT_VHOST[example.com]` often ends with `.conf` (e.g. `example.com.conf`).
- If a mapping starts with `/`, it is treated as an **absolute path**.
- For MySQL/MariaDB, DB name/user are auto-detected from each site’s `wp-config.php` when not provided.
- For PostgreSQL projects, set `PROJECT_DB_ENGINE[domain]="postgres"` and provide DB name/user if not discoverable.

---

## 3️⃣ Usage

Run the script:

```bash
sudo wpbr
```

You’ll see an interactive menu:

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
- Choose a project and a **version** to restore.
- Confirm by typing `RESTORE`.
- The script creates a **pre‑restore snapshot**, restores files + vhost + DB, tests the web server, and restarts PHP‑FPM if detected.

---

## 💾 Backup Structure

For each project and each run (date folder `YYYYMMDD`):

```
/var/www/backup/<domain>/<YYYYMMDD>/
├── <timestamp>_files.tar.gz        # Site files (WordPress root)
├── db_<timestamp>.sql.gz           # Database dump
└── <vhost_filename>                # Nginx/Apache vhost file
```

`<timestamp>` is `YYYYMMDDHHMMSS`, allowing multiple backups per day.

---

## 🧠 Logs & Retention

- Run logs: `/var/log/wp-backup-restore/run_<timestamp>.log`
- Latest run: `/var/log/wp-backup-restore/latest.log`
- Old logs pruned automatically per `LOG_RETENTION_DAYS`.

View live log output:

```bash
sudo tail -f /var/log/wp-backup-restore/latest.log
```

---

## ⏰ Cron Automation (Optional)

Nightly backup of **ALL** projects at 2:00 AM:

```bash
sudo crontab -e
```

Add:

```cron
0 2 * * * /opt/wp-backup-restore/script.sh >/dev/null 2>&1
```

> Make sure your `settings.conf` is configured correctly before enabling cron.

---

## 🧯 Troubleshooting

| Issue | Hint |
|------|------|
| `Permission denied` | Run with `sudo`. Ensure `/var/www/backup` is writable. |
| Nginx/Apache reload fails | Run `nginx -t` or `apache2ctl -t` to validate config; fix and retry. |
| MySQL/MariaDB prompts every time | That’s expected for secure password input (`-p`). |
| PostgreSQL auth errors | Ensure correct user privileges; check `pg_hba.conf`. |
| Wrong vhost file backed up | Check `PROJECT_VHOST[domain]` and `SERVER_TYPE`. |
| Auto-detect DB failed | Provide `PROJECT_DB` and `PROJECT_DB_USER` explicitly. |

---

## 🔒 Security Notes

- Backups may include sensitive files (`wp-config.php`, uploads, etc.). Restrict permissions on `/var/www/backup` and `/var/log/wp-backup-restore`.
- Consider off‑site or encrypted backups (`rsync`, `rclone`, `gpg`, etc.).
- DB credentials are never stored; they’re requested interactively.

---

## 📜 License

MIT — free to use, modify, and distribute.

---

## 👤 Author

Maintained by [**Mohamed‑Ayoub Benjelloun**](https://github.com/benjellounayoub).  
Contributions and pull requests are welcome.
