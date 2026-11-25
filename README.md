# MySQL → Google Drive Daily Backup

Dumps the MySQL databases listed in `databases.json`, compresses them, and uploads them to Google Drive with [rclone](https://rclone.org). Runs daily from cron.

| Item | Location |
|---|---|
| Script | `/opt/db-backup/mysql_gdrive_backup.sh` |
| Database list | `/opt/db-backup/databases.json` |
| MySQL credentials | `/root/.my.cnf` |
| rclone config | `/root/.config/rclone/rclone.conf` |
| Local backups | `/var/backups/mysql/` |
| Google Drive folder | `gdrive:mysql-backups/<database>/` |
| Log | `/var/log/mysql_gdrive_backup.log` |

All commands below are run as **root** (`sudo -i`), because cron runs the backup as root and reads root's `~/.my.cnf` and rclone config.

---

## 1. Install required packages

```bash
apt update && apt install -y jq mysql-client gzip
curl https://rclone.org/install.sh | bash
rclone version
```

> Ubuntu 18.04's packaged `rclone` is too old for Google Drive — use the official installer above.

---

## 2. Create a MySQL backup user

Log in to MySQL (`mysql -u root -p`) and run:

```sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'STRONG_PASSWORD';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
```

## 3. Store the MySQL credentials

```bash
nano /root/.my.cnf
```

```ini
[client]
user=backup
password=STRONG_PASSWORD
```

```bash
chmod 600 /root/.my.cnf
mysql -e "SHOW DATABASES;"     # should work without a password prompt
```

---

## 4. Connect rclone to Google Drive

> **Do not paste the Google `client_secret_*.json` file into `rclone.conf`.**
> `rclone.conf` uses its own INI format; pasting the JSON there causes
> `invalid_client` errors. Create the remote with `rclone config` instead.

### 4a. (Optional) Use your own Google client ID

rclone's built-in client works fine for a few daily uploads. To use your own:

1. Google Cloud Console → **APIs & Services → Library** → enable **Google Drive API**.
2. **OAuth consent screen** → set publishing status to **In production**
   (in *Testing*, tokens expire after 7 days and backups start failing with `invalid_grant`).
3. **Credentials → Create credentials → OAuth client ID** → type **Desktop app**.
4. Note the **Client ID** and **Client secret** (from the downloaded JSON).

### 4b. Create the remote

```bash
rclone config
```

| Prompt | Answer |
|---|---|
| `n/s/q>` | `n` (new remote) |
| `name>` | `gdrive` |
| `Storage>` | `drive` |
| `client_id>` | your Client ID, or blank for rclone's built-in client |
| `client_secret>` | your Client secret, or blank |
| `scope>` | `1` (full access) or `3` (`drive.file`, only files rclone creates) |
| `service_account_file>` | blank |
| `Edit advanced config?` | `n` |
| `Use web browser to automatically authenticate?` | see below |
| `Configure this as a Shared Drive?` | `n` |

**Authenticating on a server without a browser** — pick one:

- **SSH tunnel (easiest):** connect with
  `ssh -L 53682:localhost:53682 root@<server-ip>`, answer **`y`**, and open the
  `http://127.0.0.1:53682/auth?...` link it prints in your laptop's browser.
- **Remote authorize:** answer **`n`**, copy the `rclone authorize "drive" "eyJ..."`
  command, run it **on your laptop** (with rclone installed), sign in, and paste
  the `{"access_token": ...}` result it prints back at `config_token>`.
  *Do not paste the `eyJ...` string itself — that stores an empty token.*

### 4c. Verify

```bash
chmod 600 /root/.config/rclone/rclone.conf
rclone mkdir gdrive:mysql-backups
rclone lsd gdrive:
```

---

## 5. Install the backup script

```bash
mkdir -p /opt/db-backup /var/backups/mysql
cp mysql_gdrive_backup.sh databases.json /opt/db-backup/
chmod 700 /opt/db-backup/mysql_gdrive_backup.sh
chmod 600 /opt/db-backup/databases.json
nano /opt/db-backup/databases.json      # list the databases to back up
```

Run it once by hand and check the result:

```bash
/opt/db-backup/mysql_gdrive_backup.sh
tail -20 /var/log/mysql_gdrive_backup.log
rclone ls gdrive:mysql-backups
```

---

## 6. Schedule the daily backup

```bash
echo '30 2 * * * root /opt/db-backup/mysql_gdrive_backup.sh >> /var/log/mysql_gdrive_backup.log 2>&1' \
  > /etc/cron.d/mysql-gdrive-backup
chmod 644 /etc/cron.d/mysql-gdrive-backup
```

Runs every day at 02:30 server time (check with `timedatectl`).

---

## Restore a backup

```bash
rclone ls gdrive:mysql-backups/<database>/
rclone copy gdrive:mysql-backups/<database>/<file>.sql.gz /tmp/
zcat /tmp/<file>.sql.gz | mysql <database>
```

If the dump was made with `--databases`, it already contains `CREATE DATABASE`/`USE`, so run `zcat ... | mysql` without a database name.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `empty token found - please run "rclone config reconnect gdrive:"` | Wrong value pasted at `config_token>` | `rclone config reconnect gdrive:` and follow step 4b |
| `invalid_client` | Client ID/secret in `rclone.conf` is wrong, deleted, or the JSON file was pasted into the config | Check them in Cloud Console, then `rclone config update gdrive client_id "..." client_secret "..."` and `rclone config reconnect gdrive:` — or set both to `""` to use rclone's built-in client |
| `invalid_grant` | Token expired or revoked (often: consent screen still in *Testing*) | Publish the consent screen, then `rclone config reconnect gdrive:` |
| `Access denied for user 'backup'` | Wrong password or missing grants | Check `/root/.my.cnf` and step 2 |
| `rclone remote not configured for user root` | Remote was set up as a different user | Run `rclone config` as root, or check `rclone config file` |

Upload a backup that failed to upload:

```bash
rclone copy /var/backups/mysql/<file>.sql.gz gdrive:mysql-backups/<database>/
```

---

## Security notes

- Keep `/root/.my.cnf`, `rclone.conf` and `databases.json` at `chmod 600`.
- `rclone.conf` contains your Google token and client secret — never commit it or share it.
- Don't store the downloaded `client_secret_*.json` on the server once the remote is configured.
