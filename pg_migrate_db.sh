#!/usr/bin/env bash
#
# pg_migrate_db.sh — Migrate a single PostgreSQL database between servers,
# carrying its owning role (the "custom user") across as well.
#
# What it does, in order:
#   1. Connects to the SOURCE with admin credentials.
#   2. Auto-detects the database's owner role.
#   3. Dumps that role via `pg_dumpall --roles-only` and keeps only the
#      statements for that role — this preserves the encrypted password hash
#      (SCRAM-SHA-256 / md5), so the password is never seen in plaintext and
#      is identical on the target.
#   4. Recreates the role on the TARGET (skipped if it already exists, so an
#      existing password is never clobbered — override with --force-role).
#   5. Creates the target database owned by that role.
#   6. Dumps the source database (custom format) and restores it to the target,
#      preserving object ownership.
#
# Credentials are NEVER hardcoded. Passwords come from the standard libpq
# mechanisms: PGPASSWORD env vars (see below) or a ~/.pgpass file.
#
# Usage:
#   ./pg_migrate_db.sh --db <dbname> \
#       --src-host H --src-admin postgres [--src-port 5432] \
#       --dst-host H --dst-admin postgres [--dst-port 5432] \
#       [--dst-db <newname>] [--force-role] [--drop-existing] [--keep-dumps]
#
# Passwords (set whichever apply before running):
#   export SRC_PGPASSWORD='...'   # source admin password
#   export DST_PGPASSWORD='...'   # target admin password
#   (or configure ~/.pgpass; the script falls back to it if these are unset.)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------
SRC_HOST="" ; SRC_PORT="5432" ; SRC_ADMIN="postgres"
DST_HOST="" ; DST_PORT="5432" ; DST_ADMIN="postgres"
DB="" ; DST_DB="" ; FORCE_ROLE=0 ; DROP_EXISTING=0 ; KEEP_DUMPS=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*" >&2; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Load an env file sitting next to this script, if present: ".env.pg" is
# preferred, else ".env". Any variable set there (SRC_PGPASSWORD, DST_PGPASSWORD,
# SRC_HOST, DST_HOST, ports, admins, …) becomes an exported default.
# Precedence: CLI flags > env file > built-in defaults.
# Override the path with ENV_FILE=/some/other/file.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${ENV_FILE:-}" ]]; then
  if   [[ -f "$SCRIPT_DIR/.env.pg" ]]; then ENV_FILE="$SCRIPT_DIR/.env.pg"
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
    --db)            DB="$2"; shift 2 ;;
    --dst-db)        DST_DB="$2"; shift 2 ;;
    --src-host)      SRC_HOST="$2"; shift 2 ;;
    --src-port)      SRC_PORT="$2"; shift 2 ;;
    --src-admin)     SRC_ADMIN="$2"; shift 2 ;;
    --dst-host)      DST_HOST="$2"; shift 2 ;;
    --dst-port)      DST_PORT="$2"; shift 2 ;;
    --dst-admin)     DST_ADMIN="$2"; shift 2 ;;
    --force-role)    FORCE_ROLE=1; shift ;;
    --drop-existing) DROP_EXISTING=1; shift ;;
    --keep-dumps)    KEEP_DUMPS=1; shift ;;
    -h|--help)       usage 0 ;;
    *)               die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$DB"       ]] || die "--db is required"
[[ -n "$SRC_HOST" ]] || die "--src-host is required"
[[ -n "$DST_HOST" ]] || die "--dst-host is required"
DST_DB="${DST_DB:-$DB}"

for bin in psql pg_dump pg_dumpall pg_restore; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

# ---------------------------------------------------------------------------
# Connection helpers. We keep source/target creds isolated by exporting
# PGPASSWORD only for the duration of each command via a subshell env.
# ---------------------------------------------------------------------------
src_env() { PGPASSWORD="${SRC_PGPASSWORD:-${PGPASSWORD:-}}" "$@"; }
dst_env() { PGPASSWORD="${DST_PGPASSWORD:-${PGPASSWORD:-}}" "$@"; }

src_psql() {  # $1 = sql, connects to source admin db 'postgres'
  src_env psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_ADMIN" \
    -d postgres -tAqX -c "$1"
}
dst_psql() {  # $1 = sql, $2 = db (default postgres)
  dst_env psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_ADMIN" \
    -d "${2:-postgres}" -tAqX -c "$1"
}

# ---------------------------------------------------------------------------
# Working directory for dumps
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pgmig.${DB}.XXXXXX")"
cleanup() { [[ "$KEEP_DUMPS" -eq 1 ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT
ROLE_SQL="$WORKDIR/role.sql"
DB_DUMP="$WORKDIR/${DB}.dump"

# ---------------------------------------------------------------------------
# 0. Connectivity + existence checks
# ---------------------------------------------------------------------------
info "Checking source connectivity ($SRC_ADMIN@$SRC_HOST:$SRC_PORT)…"
src_psql "SELECT 1" >/dev/null || die "cannot connect to source"

info "Checking target connectivity ($DST_ADMIN@$DST_HOST:$DST_PORT)…"
dst_psql "SELECT 1" >/dev/null || die "cannot connect to target"

exists="$(src_psql "SELECT 1 FROM pg_database WHERE datname = '${DB//\'/\'\'}'")"
[[ "$exists" == "1" ]] || die "database '$DB' does not exist on source"

# ---------------------------------------------------------------------------
# 1. Detect the owning role (the "custom user")
# ---------------------------------------------------------------------------
OWNER="$(src_psql "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB//\'/\'\'}'")"
[[ -n "$OWNER" ]] || die "could not determine owner of '$DB'"
info "Database owner (custom user) detected: '$OWNER'"

case "$OWNER" in
  postgres|pg_*|rds_superuser|azure_pg_admin|cloudsqlsuperuser)
    info "WARNING: owner '$OWNER' looks like a built-in/admin role; it will"
    info "         NOT be recreated — only referenced during restore." ;;
esac

# ---------------------------------------------------------------------------
# 2. Dump the owner role (with its encrypted password) from the source
# ---------------------------------------------------------------------------
info "Dumping role definition for '$OWNER' (with encrypted password)…"
# --roles-only emits CREATE/ALTER ROLE including the SCRAM/md5 password hash.
src_env pg_dumpall -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_ADMIN" \
  --roles-only > "$WORKDIR/all_roles.sql"

# Keep only CREATE/ALTER ROLE lines for our specific owner. Role names are
# emitted quoted only when necessary, so match both quoted and bare forms.
awk -v r="$OWNER" '
  $0 ~ ("^(CREATE|ALTER) ROLE \"?" r "\"?([ ;])") { print }
' "$WORKDIR/all_roles.sql" > "$ROLE_SQL"

[[ -s "$ROLE_SQL" ]] || die "no role statements found for '$OWNER' in dump"
info "Captured $(wc -l < "$ROLE_SQL") role statement(s) (password hash preserved)."

# ---------------------------------------------------------------------------
# 3. Recreate the role on the target
# ---------------------------------------------------------------------------
role_exists="$(dst_psql "SELECT 1 FROM pg_roles WHERE rolname = '${OWNER//\'/\'\'}'")"
if [[ "$role_exists" == "1" && "$FORCE_ROLE" -eq 0 ]]; then
  info "Role '$OWNER' already exists on target — leaving it (and its password)"
  info "untouched. Pass --force-role to re-apply the source definition."
else
  if [[ "$role_exists" == "1" ]]; then
    info "Re-applying role definition for '$OWNER' on target (--force-role)…"
    # CREATE ROLE would fail if it exists; keep only ALTER lines in that case.
    grep -E '^ALTER ROLE ' "$ROLE_SQL" > "$WORKDIR/role_apply.sql" || true
  else
    info "Creating role '$OWNER' on target…"
    cp "$ROLE_SQL" "$WORKDIR/role_apply.sql"
  fi
  dst_env psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_ADMIN" \
    -d postgres -v ON_ERROR_STOP=1 -f "$WORKDIR/role_apply.sql"
fi

# ---------------------------------------------------------------------------
# 4. Create the target database owned by the role
# ---------------------------------------------------------------------------
dst_exists="$(dst_psql "SELECT 1 FROM pg_database WHERE datname = '${DST_DB//\'/\'\'}'")"
if [[ "$dst_exists" == "1" ]]; then
  if [[ "$DROP_EXISTING" -eq 1 ]]; then
    info "Dropping existing target database '$DST_DB'…"
    dst_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DST_DB//\'/\'\'}' AND pid <> pg_backend_pid()" >/dev/null || true
    dst_env psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_ADMIN" \
      -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE \"$DST_DB\""
    dst_exists="0"
  else
    die "target database '$DST_DB' already exists (use --drop-existing to replace)"
  fi
fi

info "Creating target database '$DST_DB' owned by '$OWNER'…"
dst_env psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_ADMIN" \
  -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE \"$DST_DB\" OWNER \"$OWNER\""

# ---------------------------------------------------------------------------
# 5. Dump + restore the database contents
# ---------------------------------------------------------------------------
info "Dumping source database '$DB' (custom format)…"
# Custom format (-Fc) keeps ownership and ACL statements by default, so the
# objects will be owned by '$OWNER' on restore.
src_env pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_ADMIN" \
  -d "$DB" -Fc -f "$DB_DUMP"

info "Restoring into target database '$DST_DB'…"
# Ownership and grants are preserved (the role now exists on the target).
# pg_restore continues past non-fatal errors by default; we log them.
dst_env pg_restore -h "$DST_HOST" -p "$DST_PORT" -U "$DST_ADMIN" \
  -d "$DST_DB" "$DB_DUMP" 2> "$WORKDIR/restore.log" || {
    info "pg_restore reported issues; tail of log:"
    tail -n 20 "$WORKDIR/restore.log" >&2
  }

# ---------------------------------------------------------------------------
# 6. Post-migration verification
# ---------------------------------------------------------------------------
src_tables="$(src_env psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_ADMIN" -d "$DB" -tAqX \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')")"
dst_tables="$(dst_env psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_ADMIN" -d "$DST_DB" -tAqX \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')")"

info "Table count — source: $src_tables, target: $dst_tables"
if [[ "$src_tables" == "$dst_tables" ]]; then
  info "Migration complete. Database '$DST_DB' owned by '$OWNER' on $DST_HOST."
else
  info "WARNING: table counts differ. Review $WORKDIR/restore.log (run with --keep-dumps)."
  exit 2
fi
