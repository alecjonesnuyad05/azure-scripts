#!/usr/bin/env bash
#
# azure_migrate_disk.sh — Migrate an Azure managed VM disk from a source
# subscription/tenant to a destination subscription/tenant (cross-tenant
# safe), without requiring any AAD trust or RBAC between the two tenants.
#
# Cross-tenant managed-disk copy (`az disk create --source <disk-id>`) only
# works within the same tenant, because it relies on AAD-based RBAC to read
# the source disk. To cross a tenant boundary we instead move the bytes over
# plain HTTPS using SAS tokens, which are storage-account-scoped and carry no
# AAD/tenant dependency at all:
#
# What it does, in order:
#   1. Logs into the SOURCE tenant/subscription (service principal, if
#      SRC_AZURE_* creds are set, else assumes an existing `az login` session
#      that already has that subscription in its token cache).
#   2. Snapshots the source disk (so the live disk/VM is untouched — no
#      downtime required, though see the consistency note below) and grants
#      a time-limited, read-only SAS on that snapshot.
#   3. Logs into the DESTINATION tenant/subscription and provisions (or
#      reuses) a staging storage account + container there.
#   4. Runs `azcopy copy <source SAS URL> <dest SAS URL>` — a plain
#      SAS-to-SAS blob copy, so it never needs both tenants authenticated at
#      once and never needs cross-tenant RBAC.
#   5. Creates the destination managed disk `--source`-ing that staged blob
#      (same-tenant blob → disk, so ordinary RBAC applies here).
#   6. Revokes/deletes the source snapshot and (unless --keep-staging)
#      deletes the staged blob, then verifies disk size matches.
#
# Consistency note: a snapshot of an in-use disk on a running VM is
# crash-consistent, not necessarily application-consistent. For a clean copy,
# stop/deallocate the source VM first; this script does not do that for you.
#
# Credentials are NEVER hardcoded. Service principal secrets come from
# SRC_AZURE_CLIENT_SECRET / DST_AZURE_CLIENT_SECRET (env or .env file); if
# unset, the script skips `az login` for that side and expects the
# subscription to already be usable via an existing `az login` session.
#
# Usage:
#   ./azure_migrate_disk.sh --disk <name> \
#       --src-rg <rg> --src-subscription <id> [--src-tenant <id>] \
#       --dst-rg <rg> --dst-subscription <id> [--dst-tenant <id>] \
#       [--dst-disk <newname>] [--dst-location <region>] [--sku <sku>] \
#       [--staging-account <name>] [--staging-container <name>] \
#       [--sas-duration <seconds>] [--drop-existing] [--keep-staging]
#
# Service principal creds (set whichever side needs a fresh login, or put
# them in .env.azure):
#   export SRC_AZURE_TENANT_ID='...'
#   export SRC_AZURE_CLIENT_ID='...'
#   export SRC_AZURE_CLIENT_SECRET='...'
#   export DST_AZURE_TENANT_ID='...'
#   export DST_AZURE_CLIENT_ID='...'
#   export DST_AZURE_CLIENT_SECRET='...'
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------
DISK="" ; DST_DISK=""
SRC_RG="" ; SRC_SUB="" ; SRC_TENANT=""
DST_RG="" ; DST_SUB="" ; DST_TENANT=""
DST_LOCATION="" ; SKU=""
STAGING_ACCOUNT="" ; STAGING_CONTAINER="diskmigration"
SAS_DURATION="14400"   # 4 hours
DROP_EXISTING=0 ; KEEP_STAGING=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*" >&2; }

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Load an env file sitting next to this script: ".env.azure" is preferred,
# else ".env" (override with ENV_FILE=...). Precedence: CLI flags > file >
# built-in defaults.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${ENV_FILE:-}" ]]; then
  if   [[ -f "$SCRIPT_DIR/.env.azure" ]]; then ENV_FILE="$SCRIPT_DIR/.env.azure"
  else ENV_FILE="$SCRIPT_DIR/.env"; fi
fi
if [[ -f "$ENV_FILE" ]]; then
  info "Loading configuration from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)               DISK="$2"; shift 2 ;;
    --dst-disk)           DST_DISK="$2"; shift 2 ;;
    --src-rg)             SRC_RG="$2"; shift 2 ;;
    --src-subscription)   SRC_SUB="$2"; shift 2 ;;
    --src-tenant)         SRC_TENANT="$2"; shift 2 ;;
    --dst-rg)             DST_RG="$2"; shift 2 ;;
    --dst-subscription)   DST_SUB="$2"; shift 2 ;;
    --dst-tenant)         DST_TENANT="$2"; shift 2 ;;
    --dst-location)       DST_LOCATION="$2"; shift 2 ;;
    --sku)                SKU="$2"; shift 2 ;;
    --staging-account)    STAGING_ACCOUNT="$2"; shift 2 ;;
    --staging-container)  STAGING_CONTAINER="$2"; shift 2 ;;
    --sas-duration)       SAS_DURATION="$2"; shift 2 ;;
    --drop-existing)      DROP_EXISTING=1; shift ;;
    --keep-staging)       KEEP_STAGING=1; shift ;;
    -h|--help)            usage 0 ;;
    *)                    die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$DISK"    ]] || die "--disk is required"
[[ -n "$SRC_RG"  ]] || die "--src-rg is required"
[[ -n "$SRC_SUB" ]] || die "--src-subscription is required"
[[ -n "$DST_RG"  ]] || die "--dst-rg is required"
[[ -n "$DST_SUB" ]] || die "--dst-subscription is required"
DST_DISK="${DST_DISK:-$DISK}"

for bin in az azcopy; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

SNAPSHOT_NAME="${DISK}-migsnap-$(date +%Y%m%d%H%M%S)"
BLOB_NAME="${DISK}.vhd"

# ---------------------------------------------------------------------------
# Context helpers — switch the active az CLI subscription, logging in with a
# service principal first if creds were supplied for that side.
# ---------------------------------------------------------------------------
use_src() {
  if [[ -n "${SRC_AZURE_CLIENT_SECRET:-}" ]]; then
    [[ -n "${SRC_AZURE_CLIENT_ID:-}" && -n "${SRC_AZURE_TENANT_ID:-}" ]] \
      || die "SRC_AZURE_CLIENT_SECRET set but SRC_AZURE_CLIENT_ID/SRC_AZURE_TENANT_ID missing"
    az login --service-principal -u "$SRC_AZURE_CLIENT_ID" \
      -p "$SRC_AZURE_CLIENT_SECRET" --tenant "$SRC_AZURE_TENANT_ID" -o none
  fi
  az account set --subscription "$SRC_SUB"
}
use_dst() {
  if [[ -n "${DST_AZURE_CLIENT_SECRET:-}" ]]; then
    [[ -n "${DST_AZURE_CLIENT_ID:-}" && -n "${DST_AZURE_TENANT_ID:-}" ]] \
      || die "DST_AZURE_CLIENT_SECRET set but DST_AZURE_CLIENT_ID/DST_AZURE_TENANT_ID missing"
    az login --service-principal -u "$DST_AZURE_CLIENT_ID" \
      -p "$DST_AZURE_CLIENT_SECRET" --tenant "$DST_AZURE_TENANT_ID" -o none
  fi
  az account set --subscription "$DST_SUB"
}

# ---------------------------------------------------------------------------
# Cleanup: always revoke/drop the source snapshot; drop the staged blob
# unless --keep-staging was passed.
# ---------------------------------------------------------------------------
cleanup() {
  info "Cleaning up…"
  use_src 2>/dev/null || true
  az snapshot revoke-access -g "$SRC_RG" -n "$SNAPSHOT_NAME" -o none 2>/dev/null || true
  az snapshot delete -g "$SRC_RG" -n "$SNAPSHOT_NAME" --yes -o none 2>/dev/null || true
  if [[ "$KEEP_STAGING" -eq 0 && -n "$STAGING_ACCOUNT" ]]; then
    use_dst 2>/dev/null || true
    az storage blob delete --account-name "$STAGING_ACCOUNT" --account-key "${STAGING_KEY:-}" \
      -c "$STAGING_CONTAINER" -n "$BLOB_NAME" -o none 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0. Source side: locate the disk, snapshot it, grant a read-only SAS
# ---------------------------------------------------------------------------
info "Switching to source subscription ($SRC_SUB)…"
use_src

info "Reading source disk '$DISK' in resource group '$SRC_RG'…"
DISK_ID="$(az disk show -g "$SRC_RG" -n "$DISK" --query id -o tsv)" \
  || die "source disk '$DISK' not found in '$SRC_RG'"
SRC_SIZE_GB="$(az disk show -g "$SRC_RG" -n "$DISK" --query diskSizeGB -o tsv)"
SRC_LOCATION="$(az disk show -g "$SRC_RG" -n "$DISK" --query location -o tsv)"
SRC_SKU="$(az disk show -g "$SRC_RG" -n "$DISK" --query sku.name -o tsv)"
DST_LOCATION="${DST_LOCATION:-$SRC_LOCATION}"
SKU="${SKU:-$SRC_SKU}"
info "Source disk: ${SRC_SIZE_GB}GB, sku=$SRC_SKU, location=$SRC_LOCATION"

info "Snapshotting source disk as '$SNAPSHOT_NAME'…"
az snapshot create -g "$SRC_RG" -n "$SNAPSHOT_NAME" --source "$DISK_ID" \
  --incremental false -o none

info "Granting a ${SAS_DURATION}s read-only SAS on the snapshot…"
SRC_SAS_URL="$(az snapshot grant-access -g "$SRC_RG" -n "$SNAPSHOT_NAME" \
  --access-level Read --duration-in-seconds "$SAS_DURATION" --query accessSas -o tsv)"
[[ -n "$SRC_SAS_URL" ]] || die "failed to obtain source SAS URL"

# ---------------------------------------------------------------------------
# 1. Destination side: staging storage account + container + write SAS
# ---------------------------------------------------------------------------
info "Switching to destination subscription ($DST_SUB)…"
use_dst

az group show -g "$DST_RG" >/dev/null 2>&1 || die "destination resource group '$DST_RG' does not exist"

if [[ -z "$STAGING_ACCOUNT" ]]; then
  STAGING_ACCOUNT="diskmig$(echo -n "${DISK}${DST_RG}" | md5sum | cut -c1-16)"
fi
info "Staging storage account: $STAGING_ACCOUNT"

if ! az storage account show -g "$DST_RG" -n "$STAGING_ACCOUNT" >/dev/null 2>&1; then
  info "Creating staging storage account '$STAGING_ACCOUNT'…"
  az storage account create -g "$DST_RG" -n "$STAGING_ACCOUNT" \
    -l "$DST_LOCATION" --sku Standard_LRS --kind StorageV2 -o none
fi
STAGING_KEY="$(az storage account keys list -g "$DST_RG" -n "$STAGING_ACCOUNT" \
  --query '[0].value' -o tsv)"

az storage container show --account-name "$STAGING_ACCOUNT" --account-key "$STAGING_KEY" \
  -n "$STAGING_CONTAINER" >/dev/null 2>&1 || \
  az storage container create --account-name "$STAGING_ACCOUNT" --account-key "$STAGING_KEY" \
    -n "$STAGING_CONTAINER" -o none

EXPIRY="$(date -u -d "+${SAS_DURATION} seconds" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
  || date -u -v"+${SAS_DURATION}S" '+%Y-%m-%dT%H:%MZ')"
DST_SAS_TOKEN="$(az storage blob generate-sas --account-name "$STAGING_ACCOUNT" \
  --account-key "$STAGING_KEY" -c "$STAGING_CONTAINER" -n "$BLOB_NAME" \
  --permissions cw --expiry "$EXPIRY" -o tsv)"
DST_BLOB_URL="https://${STAGING_ACCOUNT}.blob.core.windows.net/${STAGING_CONTAINER}/${BLOB_NAME}"
DST_SAS_URL="${DST_BLOB_URL}?${DST_SAS_TOKEN}"

# ---------------------------------------------------------------------------
# 2. Copy the bytes — plain SAS-to-SAS transfer, no AAD/tenant involvement
# ---------------------------------------------------------------------------
info "Copying snapshot to staging blob via azcopy (this is the slow part)…"
azcopy copy "$SRC_SAS_URL" "$DST_SAS_URL" --blob-type PageBlob

# ---------------------------------------------------------------------------
# 3. Create the destination managed disk from the staged blob
# ---------------------------------------------------------------------------
dst_exists=0
if az disk show -g "$DST_RG" -n "$DST_DISK" >/dev/null 2>&1; then
  dst_exists=1
  if [[ "$DROP_EXISTING" -eq 1 ]]; then
    info "Deleting existing destination disk '$DST_DISK'…"
    az disk delete -g "$DST_RG" -n "$DST_DISK" --yes -o none
    dst_exists=0
  else
    die "destination disk '$DST_DISK' already exists (use --drop-existing to replace)"
  fi
fi

info "Creating destination disk '$DST_DISK' in '$DST_RG' from staged blob…"
az disk create -g "$DST_RG" -n "$DST_DISK" -l "$DST_LOCATION" --sku "$SKU" \
  --source "$DST_BLOB_URL" -o none

# ---------------------------------------------------------------------------
# 4. Verification
# ---------------------------------------------------------------------------
DST_SIZE_GB="$(az disk show -g "$DST_RG" -n "$DST_DISK" --query diskSizeGB -o tsv)"
info "Disk size — source: ${SRC_SIZE_GB}GB, destination: ${DST_SIZE_GB}GB"
if [[ "$SRC_SIZE_GB" == "$DST_SIZE_GB" ]]; then
  info "Migration complete. Disk '$DST_DISK' created in '$DST_RG' ($DST_SUB)."
else
  info "WARNING: disk sizes differ. Investigate before relying on '$DST_DISK'."
  exit 2
fi
