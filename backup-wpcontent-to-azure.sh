#!/usr/bin/env bash
#
# backup-wpcontent-to-azure.sh
#
# Archives a WordPress wp-content directory and uploads it to an Azure Blob
# Storage container using azcopy. Designed to run from a Linux VM (e.g. a
# Hetzner box) on a cron schedule.
#
# Requirements:
#   - bash, tar, gzip, flock
#   - azcopy  --  https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10
#   - Azure CLI (`az`) is OPTIONAL: used to pre-create the container, to derive
#     a SAS from an account key, and for retention pruning. Not needed if you
#     provide AZ_SAS_TOKEN and skip retention.
#
# Configuration is read from environment variables. Put them in a root-owned,
# chmod 600 env file and source it, or export them from your cron wrapper.
# NEVER commit real credentials.
#
# Required env vars:
#   WP_CONTENT_DIR         Absolute path to wp-content (e.g. /var/www/site/wp-content)
#   AZ_STORAGE_ACCOUNT     Azure storage account name
#   AZ_CONTAINER           Blob container name (created if missing)
#   One auth method, in order of preference:
#     AZ_SAS_TOKEN         SAS token ("?..." or "sv=...") -- recommended, azcopy-native
#     AZ_STORAGE_KEY       Storage account key (requires `az` to mint a short SAS)
#     AZ_USE_LOGIN=1       Use an existing azcopy login session (run `azcopy login` first)
#
# Optional env vars:
#   BACKUP_NAME_PREFIX     Blob/file name prefix           (default: wp-content)
#   LOCAL_TMP_DIR          Where the archive is built      (default: /tmp)
#   KEEP_LOCAL             Keep the local archive after upload (default: 0 = delete)
#   RETENTION_DAYS         Delete blobs older than N days   (default: 0 = disabled; needs az)
#   BLOB_TIER              Access tier: Hot|Cool|Cold|Archive (default: unset)
#   TAR_EXTRA_EXCLUDES     Extra --exclude globs, space-separated
#   AZ_BLOB_ENDPOINT       Blob endpoint suffix             (default: blob.core.windows.net)
#
# Exit codes: 0 ok, 1 config error, 2 archive error, 3 upload error.

set -euo pipefail

log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "${*:2}"; }
die() { log ERROR "${*:2}"; exit "$1"; }

# --- Config & defaults -------------------------------------------------------
: "${WP_CONTENT_DIR:?WP_CONTENT_DIR is required}"
: "${AZ_STORAGE_ACCOUNT:?AZ_STORAGE_ACCOUNT is required}"
: "${AZ_CONTAINER:?AZ_CONTAINER is required}"

BACKUP_NAME_PREFIX="${BACKUP_NAME_PREFIX:-wp-content}"
LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-/tmp}"
KEEP_LOCAL="${KEEP_LOCAL:-0}"
RETENTION_DAYS="${RETENTION_DAYS:-0}"
BLOB_TIER="${BLOB_TIER:-}"
TAR_EXTRA_EXCLUDES="${TAR_EXTRA_EXCLUDES:-}"
AZ_BLOB_ENDPOINT="${AZ_BLOB_ENDPOINT:-blob.core.windows.net}"

[ -d "$WP_CONTENT_DIR" ] || die 1 "WP_CONTENT_DIR does not exist: $WP_CONTENT_DIR"
command -v azcopy >/dev/null 2>&1 || die 1 "azcopy not found on PATH"
command -v tar    >/dev/null 2>&1 || die 1 "tar not found on PATH"

HAVE_AZ=0
command -v az >/dev/null 2>&1 && HAVE_AZ=1

ACCOUNT_URL="https://${AZ_STORAGE_ACCOUNT}.${AZ_BLOB_ENDPOINT}"

# --- Resolve auth into a SAS query string (or an azcopy login session) -------
# SAS_QS is the token WITHOUT a leading '?'. USE_LOGIN=1 means rely on azcopy login.
SAS_QS=""
USE_LOGIN=0
# az auth args, reused for container-create / retention when az is available.
AZ_AUTH_ARGS=()

if [ -n "${AZ_SAS_TOKEN:-}" ]; then
  SAS_QS="${AZ_SAS_TOKEN#\?}"
  AZ_AUTH_ARGS=(--sas-token "$AZ_SAS_TOKEN")
elif [ -n "${AZ_STORAGE_KEY:-}" ]; then
  [ "$HAVE_AZ" = "1" ] || die 1 "AZ_STORAGE_KEY needs the az CLI to mint a SAS (or use AZ_SAS_TOKEN)"
  AZ_AUTH_ARGS=(--account-key "$AZ_STORAGE_KEY")
  # Mint a short-lived container SAS (2h) so azcopy can authenticate.
  sas_expiry="$(date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ')"
  log INFO "Minting short-lived SAS from account key (expires $sas_expiry)"
  SAS_QS="$(az storage container generate-sas \
      --account-name "$AZ_STORAGE_ACCOUNT" \
      --account-key "$AZ_STORAGE_KEY" \
      --name "$AZ_CONTAINER" \
      --permissions rwl \
      --expiry "$sas_expiry" \
      --https-only --output tsv)" || die 1 "Failed to mint SAS from account key"
  SAS_QS="${SAS_QS#\?}"
elif [ "${AZ_USE_LOGIN:-0}" = "1" ]; then
  USE_LOGIN=1
  AZ_AUTH_ARGS=(--auth-mode login)
else
  die 1 "No auth: set AZ_SAS_TOKEN, AZ_STORAGE_KEY, or AZ_USE_LOGIN=1"
fi

# --- Single-instance lock (avoid overlapping cron runs) ----------------------
LOCK_FILE="${LOCAL_TMP_DIR}/.$(basename "$0").lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die 1 "Another backup run is already in progress ($LOCK_FILE)"
fi

# --- Create the archive ------------------------------------------------------
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
HOSTTAG="$(hostname -s 2>/dev/null || echo host)"
ARCHIVE_NAME="${BACKUP_NAME_PREFIX}-${HOSTTAG}-${STAMP}.tar.gz"
ARCHIVE_PATH="${LOCAL_TMP_DIR}/${ARCHIVE_NAME}"

# Exclude caches and other churn by default; extend via TAR_EXTRA_EXCLUDES.
EXCLUDES=(
  --exclude='cache'
  --exclude='*/cache/*'
  --exclude='wp-content/uploads/cache'
  --exclude='*.log'
)
for glob in $TAR_EXTRA_EXCLUDES; do EXCLUDES+=(--exclude="$glob"); done

cleanup() {
  if [ "$KEEP_LOCAL" != "1" ] && [ -f "$ARCHIVE_PATH" ]; then
    rm -f "$ARCHIVE_PATH" && log INFO "Removed local archive $ARCHIVE_PATH"
  fi
}
trap cleanup EXIT

log INFO "Archiving $WP_CONTENT_DIR -> $ARCHIVE_PATH"
# -C into the parent so the tar stores a relative wp-content/ path.
parent_dir="$(dirname "$WP_CONTENT_DIR")"
base_dir="$(basename "$WP_CONTENT_DIR")"
if ! tar -czf "$ARCHIVE_PATH" "${EXCLUDES[@]}" -C "$parent_dir" "$base_dir"; then
  die 2 "tar failed"
fi
ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"
log INFO "Archive created ($ARCHIVE_SIZE)"

# --- Ensure the container exists (best effort; needs az) ---------------------
if [ "$HAVE_AZ" = "1" ]; then
  log INFO "Ensuring container '$AZ_CONTAINER' exists"
  az storage container create \
    --account-name "$AZ_STORAGE_ACCOUNT" \
    --name "$AZ_CONTAINER" \
    "${AZ_AUTH_ARGS[@]}" \
    --output none || log WARN "Could not verify/create container (azcopy may still create it)"
else
  log INFO "az not available; relying on azcopy to create the container if needed"
fi

# --- Upload with azcopy ------------------------------------------------------
# Build the destination blob URL. With a SAS, append it as the query string;
# with an azcopy login session, azcopy authenticates via the logged-in identity.
if [ "$USE_LOGIN" = "1" ]; then
  DEST_URL="${ACCOUNT_URL}/${AZ_CONTAINER}/${ARCHIVE_NAME}"
else
  DEST_URL="${ACCOUNT_URL}/${AZ_CONTAINER}/${ARCHIVE_NAME}?${SAS_QS}"
fi

AZCOPY_ARGS=(--overwrite=false --log-level=INFO)
[ -n "$BLOB_TIER" ] && AZCOPY_ARGS+=(--block-blob-tier "$BLOB_TIER")

log INFO "Uploading $ARCHIVE_NAME to $AZ_STORAGE_ACCOUNT/$AZ_CONTAINER via azcopy"
# Keep azcopy's plan/log files inside LOCAL_TMP_DIR so cron users don't litter $HOME.
export AZCOPY_LOG_LOCATION="${AZCOPY_LOG_LOCATION:-$LOCAL_TMP_DIR/azcopy-logs}"
export AZCOPY_JOB_PLAN_LOCATION="${AZCOPY_JOB_PLAN_LOCATION:-$LOCAL_TMP_DIR/azcopy-plans}"
if ! azcopy copy "$ARCHIVE_PATH" "$DEST_URL" "${AZCOPY_ARGS[@]}"; then
  die 3 "azcopy upload failed"
fi
log INFO "Upload complete: $ARCHIVE_NAME"

# --- Retention (optional): delete blobs older than RETENTION_DAYS ------------
if [ "$RETENTION_DAYS" -gt 0 ] 2>/dev/null; then
  if [ "$HAVE_AZ" != "1" ]; then
    log WARN "RETENTION_DAYS set but az CLI is not available; skipping pruning"
  else
    cutoff="$(date -u -d "-${RETENTION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')"
    log INFO "Pruning blobs older than $cutoff (prefix=$BACKUP_NAME_PREFIX-)"
    az storage blob list \
      --account-name "$AZ_STORAGE_ACCOUNT" \
      --container-name "$AZ_CONTAINER" \
      --prefix "${BACKUP_NAME_PREFIX}-" \
      "${AZ_AUTH_ARGS[@]}" \
      --query "[?properties.creationTime < '$cutoff'].name" \
      --output tsv | while read -r old_blob; do
        [ -z "$old_blob" ] && continue
        az storage blob delete \
          --account-name "$AZ_STORAGE_ACCOUNT" \
          --container-name "$AZ_CONTAINER" \
          --name "$old_blob" \
          "${AZ_AUTH_ARGS[@]}" \
          --output none \
          && log INFO "Deleted old blob: $old_blob"
      done
  fi
fi

log INFO "Backup finished successfully"
