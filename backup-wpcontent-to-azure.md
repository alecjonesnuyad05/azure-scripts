# WordPress `wp-content` Backup to Azure Blob Storage

Archives a WordPress `wp-content` directory into a compressed tarball and uploads
it to an Azure Blob Storage container using **azcopy**. Intended to run from a
Linux VM (e.g. a Hetzner box) on a cron schedule.

**Script:** [`backup-wpcontent-to-azure.sh`](./backup-wpcontent-to-azure.sh)

---

## What it does

1. Creates `wp-content-<host>-<UTC-timestamp>.tar.gz` from `WP_CONTENT_DIR`,
   excluding caches and `*.log` by default.
2. Ensures the target Azure container exists (creates it if missing; azcopy also
   creates it on upload if `az` isn't present).
3. Uploads the archive with `azcopy copy --overwrite=false` so a name collision
   never clobbers an existing backup.
4. Optionally prunes blobs older than `RETENTION_DAYS`.
5. Removes the local archive afterwards (unless `KEEP_LOCAL=1`).

A `flock` lock prevents overlapping cron runs. The local archive is always
cleaned up on exit via a trap, even on failure.

> **Scope:** files only. This does **not** dump the WordPress database. A full,
> restorable backup also needs a `mysqldump` of the site DB — see
> [Not included](#not-included).

---

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `bash`, `tar`, `gzip` | Archiving | Preinstalled on most Linux distros |
| `azcopy` | **Upload** (required) | <https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10> |
| `az` (Azure CLI) | Optional: container create, SAS-from-key, retention pruning | <https://learn.microsoft.com/cli/azure/install-azure-cli> |
| `flock` | Single-instance lock | Part of `util-linux` (usually preinstalled) |

> `az` is only required if you authenticate with `AZ_STORAGE_KEY` (used to mint a
> short-lived SAS for azcopy) or if you enable `RETENTION_DAYS`. With
> `AZ_SAS_TOKEN` and no retention, azcopy alone is enough.

---

## Configuration

All configuration is via environment variables. Keep them in a root-owned,
`chmod 600` env file — **never commit real credentials.**

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `WP_CONTENT_DIR` | Absolute path to `wp-content` | `/var/www/site/wp-content` |
| `AZ_STORAGE_ACCOUNT` | Azure storage account name | `mystorageacct` |
| `AZ_CONTAINER` | Blob container (created if missing) | `wp-backups` |

### Authentication (choose one, in this precedence order)

| Variable | Description |
|----------|-------------|
| `AZ_SAS_TOKEN` | SAS token (`?sv=...` or `sv=...`). **Recommended** — azcopy-native. Needs container Write / List rights (add Delete for retention). |
| `AZ_STORAGE_KEY` | Storage account key. Requires `az`, which mints a short-lived (2h) container SAS that azcopy then uses. |
| `AZ_USE_LOGIN=1` | Use an existing azcopy login session — run `azcopy login` (or `azcopy login --identity`) beforehand. |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_NAME_PREFIX` | `wp-content` | Archive / blob name prefix |
| `LOCAL_TMP_DIR` | `/tmp` | Where the archive is built and the lock lives |
| `KEEP_LOCAL` | `0` | `1` keeps the local archive after upload |
| `RETENTION_DAYS` | `0` (disabled) | Delete blobs older than N days |
| `BLOB_TIER` | _(unset)_ | Access tier via `--block-blob-tier`: `Hot` \| `Cool` \| `Cold` \| `Archive` |
| `TAR_EXTRA_EXCLUDES` | _(empty)_ | Extra `--exclude` globs, space-separated |
| `AZ_BLOB_ENDPOINT` | `blob.core.windows.net` | Blob endpoint suffix (e.g. for sovereign clouds) |

---

## Setup

### 1. Create the env file (`/etc/wp-backup.env`, `chmod 600`)

```bash
export WP_CONTENT_DIR="/var/www/yoursite/wp-content"
export AZ_STORAGE_ACCOUNT="yourstorageacct"
export AZ_CONTAINER="wp-backups"
export AZ_SAS_TOKEN="?sv=2023-...&sig=..."
export RETENTION_DAYS="30"
# export BLOB_TIER="Cool"
```

```bash
sudo chown root:root /etc/wp-backup.env
sudo chmod 600 /etc/wp-backup.env
```

### 2. Run manually to test

```bash
chmod +x backup-wpcontent-to-azure.sh
set -a && source /etc/wp-backup.env && set +a
./backup-wpcontent-to-azure.sh
```

### 3. Schedule with cron

`crontab -e` — daily at 03:00:

```cron
0 3 * * * set -a; . /etc/wp-backup.env; set +a; /path/to/backup-wpcontent-to-azure.sh >> /var/log/wp-backup.log 2>&1
```

---

## Generating a SAS token

Container-scoped SAS with the rights this script needs (write/list/delete),
valid for one year:

```bash
az storage container generate-sas \
  --account-name yourstorageacct \
  --name wp-backups \
  --permissions rwld \
  --expiry 2027-08-19 \
  --auth-mode login --as-user \
  --https-only --output tsv
```

Prefix the result with `?` when setting `AZ_SAS_TOKEN` if it doesn't already
start with one.

---

## Restore

```bash
# Download a backup
az storage blob download \
  --account-name yourstorageacct \
  --container-name wp-backups \
  --name wp-content-web1-20260819-030001.tar.gz \
  --file ./restore.tar.gz \
  --sas-token "$AZ_SAS_TOKEN"

# Extract into place (creates ./wp-content/)
tar -xzf ./restore.tar.gz -C /var/www/yoursite/
```

Fix ownership afterwards to match your web server, e.g.:

```bash
chown -R www-data:www-data /var/www/yoursite/wp-content
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Configuration / environment error |
| `2` | Archive (`tar`) failure |
| `3` | Upload / Azure error |

---

## Not included

- **Database backup.** A restorable WordPress site also needs a DB dump
  (`mysqldump`). This can be added as a step in this script or run as a
  companion script.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `azcopy not found on PATH` | Install azcopy (see Requirements) or add it to `PATH` in the cron env |
| `No auth: set AZ_SAS_TOKEN...` | No auth variable set, or env file not sourced |
| `403` / `AuthenticationFailed` on upload | SAS lacks write permission, expired, or wrong container scope; check azcopy logs in `$LOCAL_TMP_DIR/azcopy-logs` |
| `AZ_STORAGE_KEY needs the az CLI...` | Install `az`, or switch to `AZ_SAS_TOKEN` |
| `Another backup run is already in progress` | A previous run is still active or died holding the lock (`$LOCAL_TMP_DIR/.<script>.lock`) |
| Retention deletes nothing | `RETENTION_DAYS` unset/`0`, `az` missing, or blob prefix differs from `BACKUP_NAME_PREFIX` |
