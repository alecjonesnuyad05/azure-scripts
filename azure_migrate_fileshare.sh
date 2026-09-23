#!/usr/bin/env bash
#
# azure_migrate_fileshare.sh — Copy an Azure Files share from one storage
# account/subscription/tenant to another (cross-tenant safe), without
# requiring any AAD trust or RBAC between the two tenants.
#
# Same SAS-to-SAS approach as azure_migrate_container.sh, adapted for Azure
# Files (hierarchical directories, not a flat blob namespace):
#
# What it does, in order:
#   1. Logs into the SOURCE tenant/subscription (service principal, if
#      SRC_AZURE_* creds are set, else assumes an existing `az login` session
#      that already has that subscription in its token cache) — SKIPPED
#      entirely if SRC_ACCOUNT_KEY is supplied (see below).
#   2. Grants a time-limited, read+list SAS on the source share and counts
#      its files recursively via `azcopy list` (az CLI's own share listing
#      is shallow — one directory level at a time).
#   3. Logs into the DESTINATION tenant/subscription and provisions (or
#      reuses) the destination storage account + share — login SKIPPED
#      if DST_ACCOUNT_KEY is supplied, but the account must then already
#      exist (creating a storage account is a management-plane operation
#      and needs an authenticated session; the share itself can still be
#      created with just the key, since that's data-plane).
#   4. Grants a time-limited, write+create SAS on the destination share.
#   5. Runs `azcopy copy <source SAS URL> <dest SAS URL> --recursive` — a
#      plain SAS-to-SAS share copy, so it never needs both tenants
#      authenticated at once and never needs cross-tenant RBAC.
#   6. Recounts files on the destination via `azcopy list` and verifies it
#      matches the source count.
#
# Credentials are NEVER hardcoded. Two auth modes per side, tried in order:
#   1. --src-account-key / --dst-account-key (or SRC_ACCOUNT_KEY /
#      DST_ACCOUNT_KEY env/.env — shared with azure_migrate_container.sh, so
#      migrating a share from the same account reuses the same values) — the
#      storage account's own access key. If set, --src-rg/--src-subscription
#      (or dst-) are not needed at all: the key authenticates data-plane
#      calls directly, no `az login` involved. NOTE: an account key grants
#      full read/write on the *entire* account (every share/container), not
#      just this one — prefer service-principal auth below when you can, and
#      treat this key with the same care as a root password.
#   2. SRC_AZURE_CLIENT_SECRET / DST_AZURE_CLIENT_SECRET service-principal
#      creds (env or .env file); if unset, the script skips `az login` for
#      that side and expects the subscription to already be usable via an
#      existing `az login` session. The account's key is then fetched via
#      `az storage account keys list` under that session, scoped only to
#      whatever RBAC that principal/session already has.
#
# Usage:
#   ./azure_migrate_fileshare.sh --share <name> \
#       --src-account <name> --src-rg <rg> --src-subscription <id> [--src-tenant <id>] \
#       --dst-account <name> --dst-rg <rg> --dst-subscription <id> [--dst-tenant <id>] \
#       [--dst-share <newname>] [--dst-location <region>] [--dst-sku <sku>] \
#       [--dst-quota-gb <n>] [--sas-duration <seconds>] [--drop-existing] [--dry-run]
#   # or, skipping az login on one/both sides:
#   ./azure_migrate_fileshare.sh --share <name> \
#       --src-account <name> --src-account-key '...' \
#       --dst-account <name> --dst-account-key '...' \
#       [--dst-share <newname>] [--drop-existing]
#   # or, just list what shares exist in the source account (no --share or
#   # --dst-* needed) — useful for confirming the account name/key/RG are
#   # right before running a real migration:
#   ./azure_migrate_fileshare.sh --src-account <name> --src-account-key '...' --list-src-shares
#
# --list-src-shares: authenticates to the source account only, lists its
# shares (name, quota) and exits. No --share, --dst-account, or azcopy
# required for this mode.
#
# --dry-run: authenticates both sides, recursively counts the source share's
# files (via azcopy list against a read-only SAS), checks whether the
# destination account/share already exist, and prints exactly what would
# happen — but grants no write SAS, creates no account/share, runs no
# azcopy copy, and deletes no files.
#
# Service principal creds (set whichever side needs a fresh login, or put
# them in .env.azure):
#   export SRC_AZURE_TENANT_ID='...'
#   export SRC_AZURE_CLIENT_ID='...'
#   export SRC_AZURE_CLIENT_SECRET='...'
#   export DST_AZURE_TENANT_ID='...'
#   export DST_AZURE_CLIENT_ID='...'
#   export DST_AZURE_CLIENT_SECRET='...'
# Or, storage account keys (bypasses az login entirely for that side):
#   export SRC_ACCOUNT_KEY='...'
#   export DST_ACCOUNT_KEY='...'
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------
SHARE="" ; DST_SHARE=""
SRC_ACCOUNT="" ; SRC_RG="" ; SRC_SUB="" ; SRC_TENANT="" ; SRC_ACCOUNT_KEY=""
DST_ACCOUNT="" ; DST_RG="" ; DST_SUB="" ; DST_TENANT="" ; DST_ACCOUNT_KEY=""
DST_LOCATION="" ; DST_SKU="Standard_LRS" ; DST_QUOTA_GB=""
SAS_DURATION="14400"   # 4 hours
DROP_EXISTING=0 ; DRY_RUN=0 ; LIST_SRC_SHARES=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*" >&2; }

usage() { sed -n '2,85p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Runs `az "$@"` (discarding stdout); on failure, prints az's actual stderr
# before dying with $1 — so a 403/auth/network error is never masked behind
# a generic "not found" message.
az_check() {
  local msg="$1" err; shift
  err="$(az "$@" 2>&1 >/dev/null)" && return 0
  info "az error:"; printf '%s\n' "$err" | sed 's/^/         /' >&2
  die "$msg"
}

# Counts entries under a share SAS URL recursively via `azcopy list` (az
# CLI's share listing is shallow). Counts every "Content Length:" line, which
# includes directories as well as files — fine for comparing source vs.
# destination, since both are counted the same way. On failure, prints
# azcopy's actual output and returns non-zero instead of silently yielding 0.
# The SAS needs read + list (azcopy list does GetProperties calls).
count_share_entries() {
  local url="$1" out
  if ! out="$(azcopy list "$url" 2>&1)"; then
    info "azcopy list error:"; printf '%s\n' "$out" | sed 's/^/         /' >&2
    return 1
  fi
  printf '%s\n' "$out" | grep -ic 'Content Length:' || true
}

# Same shape as a plain `az ... >/dev/null 2>&1` existence check (returns
# 0/1), but if the failure looks like an auth/network problem rather than a
# genuine "not found", warns loudly instead of silently treating it as
# "doesn't exist yet" (which would otherwise go on to attempt a create).
az_exists() {
  local err
  err="$(az "$@" 2>&1 >/dev/null)" && return 0
  if printf '%s' "$err" | grep -qiE 'authorizationfailed|403|forbidden|accountiskeydisabled|keybasedauthenticationnotpermitted'; then
    info "WARNING: az reported an authorization/network error, not just \"not found\":"
    printf '%s\n' "$err" | sed 's/^/         /' >&2
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Load an env file sitting next to this script: ".env.azure" is preferred,
# else ".env" (override with ENV_FILE=...), shared with the other
# azure_migrate_*.sh scripts. Precedence: CLI flags > env file > built-in
# defaults.
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
    --share)              SHARE="$2"; shift 2 ;;
    --dst-share)          DST_SHARE="$2"; shift 2 ;;
    --src-account)        SRC_ACCOUNT="$2"; shift 2 ;;
    --src-rg)             SRC_RG="$2"; shift 2 ;;
    --src-subscription)   SRC_SUB="$2"; shift 2 ;;
    --src-tenant)         SRC_TENANT="$2"; shift 2 ;;
    --src-account-key)    SRC_ACCOUNT_KEY="$2"; shift 2 ;;
    --dst-account)        DST_ACCOUNT="$2"; shift 2 ;;
    --dst-rg)             DST_RG="$2"; shift 2 ;;
    --dst-subscription)   DST_SUB="$2"; shift 2 ;;
    --dst-tenant)         DST_TENANT="$2"; shift 2 ;;
    --dst-account-key)    DST_ACCOUNT_KEY="$2"; shift 2 ;;
    --dst-location)       DST_LOCATION="$2"; shift 2 ;;
    --dst-sku)            DST_SKU="$2"; shift 2 ;;
    --dst-quota-gb)       DST_QUOTA_GB="$2"; shift 2 ;;
    --sas-duration)       SAS_DURATION="$2"; shift 2 ;;
    --drop-existing)      DROP_EXISTING=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --list-src-shares)    LIST_SRC_SHARES=1; shift ;;
    -h|--help)            usage 0 ;;
    *)                    die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$SRC_ACCOUNT" ]] || die "--src-account is required"
if [[ -z "$SRC_ACCOUNT_KEY" ]]; then
  [[ -n "$SRC_RG"  ]] || die "--src-rg is required (unless --src-account-key is given)"
  [[ -n "$SRC_SUB" ]] || die "--src-subscription is required (unless --src-account-key is given)"
fi

if [[ "$LIST_SRC_SHARES" -eq 0 ]]; then
  [[ -n "$SHARE"       ]] || die "--share is required"
  [[ -n "$DST_ACCOUNT" ]] || die "--dst-account is required"
  if [[ -z "$DST_ACCOUNT_KEY" ]]; then
    [[ -n "$DST_RG"  ]] || die "--dst-rg is required (unless --dst-account-key is given)"
    [[ -n "$DST_SUB" ]] || die "--dst-subscription is required (unless --dst-account-key is given)"
  fi
  DST_SHARE="${DST_SHARE:-$SHARE}"
fi

if [[ "$LIST_SRC_SHARES" -eq 1 ]]; then
  command -v az >/dev/null 2>&1 || die "'az' not found on PATH"
else
  for bin in az azcopy; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
  done
fi

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
# --list-src-shares: just list what's in the source account and exit — no
# destination side, no SAS, no azcopy.
# ---------------------------------------------------------------------------
if [[ "$LIST_SRC_SHARES" -eq 1 ]]; then
  if [[ -n "$SRC_ACCOUNT_KEY" ]]; then
    info "Using supplied source account key — skipping az login."
    SRC_KEY="$SRC_ACCOUNT_KEY"
  else
    info "Switching to source subscription ($SRC_SUB)…"
    use_src
    az_check "source storage account '$SRC_ACCOUNT' not accessible in '$SRC_RG' (see az error above)" \
      storage account show -g "$SRC_RG" -n "$SRC_ACCOUNT"
    SRC_KEY="$(az storage account keys list -g "$SRC_RG" -n "$SRC_ACCOUNT" \
      --query '[0].value' -o tsv)"
  fi
  info "Shares in storage account '$SRC_ACCOUNT':"
  az storage share list --account-name "$SRC_ACCOUNT" --account-key "$SRC_KEY" \
    --query "[].{name:name, quotaGiB:properties.quota}" -o table
  exit 0
fi

# ---------------------------------------------------------------------------
# 0. Source side: locate the account/share, grant a read+list SAS, count
#    files recursively via azcopy list (az CLI's share listing is shallow).
# ---------------------------------------------------------------------------
if [[ -n "$SRC_ACCOUNT_KEY" ]]; then
  info "Using supplied source account key — skipping az login."
  SRC_KEY="$SRC_ACCOUNT_KEY"
else
  info "Switching to source subscription ($SRC_SUB)…"
  use_src
  az_check "source storage account '$SRC_ACCOUNT' not accessible in '$SRC_RG' (see az error above)" \
    storage account show -g "$SRC_RG" -n "$SRC_ACCOUNT"
  SRC_KEY="$(az storage account keys list -g "$SRC_RG" -n "$SRC_ACCOUNT" \
    --query '[0].value' -o tsv)"
fi

az_check "source share '$SHARE' not accessible in account '$SRC_ACCOUNT' (see az error above)" \
  storage share show --account-name "$SRC_ACCOUNT" --account-key "$SRC_KEY" -n "$SHARE"

EXPIRY="$(date -u -d "+${SAS_DURATION} seconds" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
  || date -u -v"+${SAS_DURATION}S" '+%Y-%m-%dT%H:%MZ')"
SRC_SAS_TOKEN="$(az storage share generate-sas --account-name "$SRC_ACCOUNT" \
  --account-key "$SRC_KEY" -n "$SHARE" --permissions rl --expiry "$EXPIRY" -o tsv)"
SRC_SAS_URL="https://${SRC_ACCOUNT}.file.core.windows.net/${SHARE}?${SRC_SAS_TOKEN}"

info "Counting source share's files recursively (azcopy list)…"
SRC_COUNT="$(count_share_entries "$SRC_SAS_URL")" \
  || die "could not list source share '$SHARE' (see azcopy error above)"
info "Source share '$SHARE' has $SRC_COUNT entries (files + directories)."

# ---------------------------------------------------------------------------
# 1. Destination side: storage account + share + write SAS
# ---------------------------------------------------------------------------
if [[ -n "$DST_ACCOUNT_KEY" ]]; then
  info "Using supplied destination account key — skipping az login."
  info "(Account creation needs an authenticated session, so the account must already exist.)"
  DST_KEY="$DST_ACCOUNT_KEY"
else
  info "Switching to destination subscription ($DST_SUB)…"
  use_dst

  az_check "destination resource group '$DST_RG' does not exist or is not accessible (see az error above)" \
    group show -g "$DST_RG"

  DST_ACCOUNT_EXISTS=1
  if ! az_exists storage account show -g "$DST_RG" -n "$DST_ACCOUNT"; then
    DST_ACCOUNT_EXISTS=0
    [[ -n "$DST_LOCATION" ]] || die "destination storage account '$DST_ACCOUNT' does not exist — pass --dst-location to create it"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "[dry-run] Would create destination storage account '$DST_ACCOUNT' ($DST_SKU, $DST_LOCATION) — skipped."
    else
      info "Creating destination storage account '$DST_ACCOUNT'…"
      az storage account create -g "$DST_RG" -n "$DST_ACCOUNT" \
        -l "$DST_LOCATION" --sku "$DST_SKU" --kind StorageV2 -o none
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 && "$DST_ACCOUNT_EXISTS" -eq 0 ]]; then
    info "[dry-run] Would copy $SRC_COUNT file(s) from '$SRC_ACCOUNT/$SHARE' into new account/share"
    info "[dry-run] '$DST_ACCOUNT/$DST_SHARE' — skipped (no account key available for further checks)."
    info "DRY RUN complete. No changes were made in either subscription."
    exit 0
  fi
  DST_KEY="$(az storage account keys list -g "$DST_RG" -n "$DST_ACCOUNT" \
    --query '[0].value' -o tsv)"
fi

if az_exists storage share show --account-name "$DST_ACCOUNT" --account-key "$DST_KEY" \
    -n "$DST_SHARE"; then
  if [[ "$DROP_EXISTING" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "[dry-run] Would delete all files in destination share '$DST_SHARE' (--drop-existing)."
    else
      info "Deleting existing files in destination share '$DST_SHARE'…"
      az storage file delete-batch --account-name "$DST_ACCOUNT" --account-key "$DST_KEY" \
        -s "$DST_SHARE" -o none
    fi
  fi
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] Would create destination share '$DST_SHARE' — skipped."
  else
    info "Creating destination share '$DST_SHARE'…"
    if [[ -n "$DST_QUOTA_GB" ]]; then
      az storage share create --account-name "$DST_ACCOUNT" --account-key "$DST_KEY" \
        -n "$DST_SHARE" --quota "$DST_QUOTA_GB" -o none
    else
      az storage share create --account-name "$DST_ACCOUNT" --account-key "$DST_KEY" \
        -n "$DST_SHARE" -o none
    fi
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would copy $SRC_COUNT file(s) from '$SRC_ACCOUNT/$SHARE' to '$DST_ACCOUNT/$DST_SHARE' via azcopy — skipped."
  info "DRY RUN complete. No changes were made in either subscription."
  exit 0
fi

DST_SAS_TOKEN="$(az storage share generate-sas --account-name "$DST_ACCOUNT" \
  --account-key "$DST_KEY" -n "$DST_SHARE" --permissions cwl --expiry "$EXPIRY" -o tsv)"
DST_SAS_URL="https://${DST_ACCOUNT}.file.core.windows.net/${DST_SHARE}?${DST_SAS_TOKEN}"

# ---------------------------------------------------------------------------
# 2. Copy — plain SAS-to-SAS transfer, no AAD/tenant involvement
# ---------------------------------------------------------------------------
info "Copying share via azcopy (this is the slow part)…"
azcopy copy "$SRC_SAS_URL" "$DST_SAS_URL" --recursive=true

# ---------------------------------------------------------------------------
# 3. Verification
# ---------------------------------------------------------------------------
info "Counting destination share's files recursively (azcopy list)…"
# Separate read+list SAS for verification — the copy SAS is deliberately
# write-only (cwl), and azcopy list needs read.
DST_VERIFY_SAS_TOKEN="$(az storage share generate-sas --account-name "$DST_ACCOUNT" \
  --account-key "$DST_KEY" -n "$DST_SHARE" --permissions rl --expiry "$EXPIRY" -o tsv)"
DST_VERIFY_URL="https://${DST_ACCOUNT}.file.core.windows.net/${DST_SHARE}?${DST_VERIFY_SAS_TOKEN}"
DST_COUNT="$(count_share_entries "$DST_VERIFY_URL")" \
  || die "copy finished but could not list destination share '$DST_SHARE' to verify (see azcopy error above)"
info "Entry count (files + directories) — source: $SRC_COUNT, destination: $DST_COUNT"
if [[ "$SRC_COUNT" == "$DST_COUNT" ]]; then
  info "Migration complete. Share '$DST_SHARE' populated in account '$DST_ACCOUNT'."
else
  info "WARNING: file counts differ. Investigate before relying on '$DST_SHARE'."
  exit 2
fi
