#!/usr/bin/env bash
#
# mysql_migrate_db.sh — Migrate a single MySQL/MariaDB database between servers,
# carrying its associated user(s) (the "custom user") across as well.
#
# MySQL has no database "owner" like PostgreSQL. The "custom user for the
# database" is taken to be every non-system account that holds privileges ON
# that schema (database-, table- or routine-level grants). Each such user is
# recreated on the target WITH its existing password hash — via
# `SHOW CREATE USER`, so the password is never seen in plaintext and stays
# identical — and its grants on this database are replayed.
#
# What it does, in order:
#   1. Connects to the SOURCE with admin credentials.
#   2. Finds the non-system users with privileges on the database.
#   3. For each: recreates it on the TARGET from `SHOW CREATE USER` (password
#      hash preserved; skipped if it already exists unless --force-user) and
#      replays its grants scoped to this database.
#   4. Creates the target database (same charset/collation as the source).
#   5. `mysqldump` the source database and loads it into the target.
#   6. Verifies base-table counts match.
#
# Credentials are NEVER hardcoded and never passed on the command line (where
# they'd show up in `ps`). The script writes short-lived, 0600 option files and
# invokes the client with --defaults-extra-file. Passwords come from env vars or
# a .env file (see below), or an existing ~/.my.cnf.
#
# Usage:
#   ./mysql_migrate_db.sh --db <dbname> \
#       --src-host H --src-admin root [--src-port 3306] \
#       --dst-host H --dst-admin root [--dst-port 3306] \
#       [--dst-db <newname>] [--force-user] [--drop-existing] [--keep-dumps] \
#       [--skip-data t1,t2 ...] [--dry-run]
#
# --skip-data <tables>: comma-separated list (repeatable) of tables whose
# DATA is not copied — the table is still created on the target with its
# full structure (columns, indexes, triggers), just empty. Useful for big
# log/session/cache/audit tables. Also settable as SKIP_DATA_TABLES in .env.
#
# --dry-run: runs every read-only check (connectivity, DB existence, which
# users hold privileges on it, whether the target DB/users already exist)
# and prints exactly what would happen, but performs no writes on either
# server — no user created/altered, no grants replayed, no database
# created/dropped, no dump/load.
#
# Passwords (set whichever apply before running, or put them in .env):
#   export SRC_MYSQL_PWD='...'   # source admin password
#   export DST_MYSQL_PWD='...'   # target admin password
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / helpers
# ---------------------------------------------------------------------------
SRC_HOST="" ; SRC_PORT="3306" ; SRC_ADMIN="root"
DST_HOST="" ; DST_PORT="3306" ; DST_ADMIN="root"
DB="" ; DST_DB="" ; FORCE_USER=0 ; DROP_EXISTING=0 ; KEEP_DUMPS=0 ; DRY_RUN=0
SKIP_DATA_TABLES="${SKIP_DATA_TABLES:-}" ; SKIP_DATA_CLI=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*" >&2; }

usage() { sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Load an env file sitting next to this script: ".env.mysql" is preferred, else
# ".env" (override with ENV_FILE=...). Precedence: CLI flags > file > defaults.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${ENV_FILE:-}" ]]; then
  if   [[ -f "$SCRIPT_DIR/.env.mysql" ]]; then ENV_FILE="$SCRIPT_DIR/.env.mysql"
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
    --force-user)    FORCE_USER=1; shift ;;
    --drop-existing) DROP_EXISTING=1; shift ;;
    --keep-dumps)    KEEP_DUMPS=1; shift ;;
    --skip-data)     SKIP_DATA_CLI="${SKIP_DATA_CLI:+$SKIP_DATA_CLI,}$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage 0 ;;
    *)               die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$DB"       ]] || die "--db is required"
[[ -n "$SRC_HOST" ]] || die "--src-host is required"
[[ -n "$DST_HOST" ]] || die "--dst-host is required"
DST_DB="${DST_DB:-$DB}"
SKIP_DATA_TABLES="${SKIP_DATA_CLI:-$SKIP_DATA_TABLES}"   # CLI replaces env file
[[ "$DRY_RUN" -eq 1 ]] && info "DRY RUN — no changes will be made on source or target."

# Resolve client binaries (MySQL or MariaDB naming).
MYSQL_BIN="$(command -v mysql || command -v mariadb || true)"
DUMP_BIN="$(command -v mysqldump || command -v mariadb-dump || true)"
[[ -n "$MYSQL_BIN" ]] || die "'mysql'/'mariadb' client not found on PATH"
[[ -n "$DUMP_BIN"  ]] || die "'mysqldump'/'mariadb-dump' not found on PATH"

# ---------------------------------------------------------------------------
# Working dir + secure option files (never pass passwords on argv).
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mysqlmig.${DB}.XXXXXX")"
cleanup() { [[ "$KEEP_DUMPS" -eq 1 ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT
SRC_CNF="$WORKDIR/src.cnf" ; DST_CNF="$WORKDIR/dst.cnf"
DB_DUMP="$WORKDIR/${DB}.sql"
SCHEMA_ONLY_DUMP="$WORKDIR/${DB}.skipdata-schema.sql"

write_cnf() { # $1=file $2=host $3=port $4=user $5=password
  umask 077
  cat > "$1" <<EOF
[client]
host=$2
port=$3
user=$4
password=$5
EOF
}
write_cnf "$SRC_CNF" "$SRC_HOST" "$SRC_PORT" "$SRC_ADMIN" "${SRC_MYSQL_PWD:-${MYSQL_PWD:-}}"
write_cnf "$DST_CNF" "$DST_HOST" "$DST_PORT" "$DST_ADMIN" "${DST_MYSQL_PWD:-${MYSQL_PWD:-}}"

# Batch, tab-separated, no header — good for scripting.
src_q() { "$MYSQL_BIN" --defaults-extra-file="$SRC_CNF" -N -B -e "$1"; }
dst_q() { "$MYSQL_BIN" --defaults-extra-file="$DST_CNF" -N -B -e "$1"; }

sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }  # for use inside '...'

# ---------------------------------------------------------------------------
# 0. Connectivity + existence
# ---------------------------------------------------------------------------
info "Checking source connectivity ($SRC_ADMIN@$SRC_HOST:$SRC_PORT)…"
src_q "SELECT 1" >/dev/null || die "cannot connect to source"
info "Checking target connectivity ($DST_ADMIN@$DST_HOST:$DST_PORT)…"
dst_q "SELECT 1" >/dev/null || die "cannot connect to target"

DBQ="$(sql_quote "$DB")"
exists="$(src_q "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DBQ'")"
[[ "$exists" == "1" ]] || die "database '$DB' does not exist on source"

# Tables whose data is skipped (structure only). Each must be a base table.
SKIP_TABLES=()
if [[ -n "$SKIP_DATA_TABLES" ]]; then
  IFS=',' read -r -a _skip <<< "$SKIP_DATA_TABLES"
  for t in "${_skip[@]}"; do
    t="${t//[[:space:]]/}"; [[ -z "$t" ]] && continue
    t_exists="$(src_q "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DBQ' AND TABLE_NAME='$(sql_quote "$t")' AND TABLE_TYPE='BASE TABLE'")"
    [[ "$t_exists" == "1" ]] || die "--skip-data: '$t' is not a base table in '$DB' on source"
    SKIP_TABLES+=("$t")
  done
  if [[ ${#SKIP_TABLES[@]} -gt 0 ]]; then info "Structure only, no data, for: ${SKIP_TABLES[*]}"; fi
fi

# ---------------------------------------------------------------------------
# 1. Find non-system users with privileges on the database
# ---------------------------------------------------------------------------
info "Detecting users with privileges on '$DB'…"
USERS="$(src_q "
  SELECT DISTINCT User, Host FROM (
    SELECT User,Host FROM mysql.db          WHERE Db='$DBQ'
    UNION SELECT User,Host FROM mysql.tables_priv WHERE Db='$DBQ'
    UNION SELECT User,Host FROM mysql.procs_priv  WHERE Db='$DBQ'
  ) g
  WHERE User <> '' AND User NOT IN
    ('root','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys')
")"

if [[ -z "$USERS" ]]; then
  info "WARNING: no non-system users hold privileges on '$DB'. Only the"
  info "         database contents will be migrated."
else
  info "Users to migrate:"; echo "$USERS" | sed 's/\t/@/; s/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# 2. Recreate each user on the target (with password hash) + replay grants
# ---------------------------------------------------------------------------
migrate_user() { # $1=user $2=host
  local u="$1" h="$2" uq hq exists_t create_stmt grants apply
  uq="$(sql_quote "$u")"; hq="$(sql_quote "$h")"

  create_stmt="$(src_q "SHOW CREATE USER '$uq'@'$hq'")"
  [[ -n "$create_stmt" ]] || { info "  ! could not read definition for $u@$h; skipping"; return; }

  exists_t="$(dst_q "SELECT 1 FROM mysql.user WHERE User='$uq' AND Host='$hq'")"
  if [[ "$exists_t" == "1" && "$FORCE_USER" -eq 0 ]]; then
    info "  = user $u@$h exists on target; leaving password/auth untouched (--force-user to re-apply)"
  elif [[ "$exists_t" == "1" ]]; then
    # CREATE USER ... -> ALTER USER ... keeps the same IDENTIFIED WITH/AS hash.
    apply="$(printf "%s" "$create_stmt" | sed 's/^CREATE USER /ALTER USER /')"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "  [dry-run] would re-apply auth for $u@$h (--force-user) — skipped"
    else
      info "  ~ re-applying auth for $u@$h (--force-user)"
      dst_q "$apply;"
    fi
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "  [dry-run] would create user $u@$h (password hash preserved) — skipped"
    else
      info "  + creating user $u@$h (password hash preserved)"
      dst_q "$create_stmt;"
    fi
  fi

  # Replay grants that reference THIS database (plus the USAGE identity line).
  # SHOW GRANTS on modern servers no longer embeds the password, so this is
  # purely about privileges. Rename to --dst-db if requested.
  grants="$(src_q "SHOW GRANTS FOR '$uq'@'$hq'")"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *"\`$DB\`."* || "$line" == "GRANT USAGE ON \`*\`.\`*\`"* || "$line" == "GRANT USAGE ON *.*"* ]]; then
      if [[ "$DST_DB" != "$DB" ]]; then
        line="${line//\`$DB\`./\`$DST_DB\`.}"
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "  [dry-run] would replay grant: $line"
      else
        dst_q "$line;" || info "  ! grant failed (continuing): $line"
      fi
    fi
  done <<< "$grants"
}

if [[ -n "$USERS" ]]; then
  while IFS=$'\t' read -r u h; do
    [[ -z "$u" ]] && continue
    migrate_user "$u" "$h"
  done <<< "$USERS"
fi

# ---------------------------------------------------------------------------
# 3. Create the target database (matching charset/collation)
# ---------------------------------------------------------------------------
read -r CHARSET COLLATION < <(src_q "
  SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
  FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DBQ'")
CHARSET="${CHARSET:-utf8mb4}"

dst_exists="$(dst_q "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_quote "$DST_DB")'")"
if [[ "$dst_exists" == "1" ]]; then
  if [[ "$DROP_EXISTING" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "[dry-run] Would drop existing target database '$DST_DB' (--drop-existing)."
    else
      info "Dropping existing target database '$DST_DB'…"
      dst_q "DROP DATABASE \`$DST_DB\`"
    fi
  else
    die "target database '$DST_DB' already exists (use --drop-existing to replace)"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would create target database '$DST_DB' (CHARSET $CHARSET, COLLATE ${COLLATION:-default}) — skipped."
  info "[dry-run] Would mysqldump source database '$DB' and load it into '$DST_DB' — skipped."
  if [[ ${#SKIP_TABLES[@]} -gt 0 ]]; then info "[dry-run] (structure only, no data, for: ${SKIP_TABLES[*]})"; fi
  info "DRY RUN complete. No changes were made on source or target."
  exit 0
fi

info "Creating target database '$DST_DB' (CHARSET $CHARSET, COLLATE ${COLLATION:-default})…"
if [[ -n "$COLLATION" ]]; then
  dst_q "CREATE DATABASE \`$DST_DB\` CHARACTER SET $CHARSET COLLATE $COLLATION"
else
  dst_q "CREATE DATABASE \`$DST_DB\` CHARACTER SET $CHARSET"
fi

# ---------------------------------------------------------------------------
# 4. Dump + load the database contents
# ---------------------------------------------------------------------------
IGNORE_ARGS=()
for t in ${SKIP_TABLES[@]+"${SKIP_TABLES[@]}"}; do IGNORE_ARGS+=("--ignore-table=$DB.$t"); done

info "Dumping source database '$DB'…"
"$DUMP_BIN" --defaults-extra-file="$SRC_CNF" \
  --single-transaction --quick --routines --triggers --events \
  --set-gtid-purged=OFF --no-tablespaces \
  ${IGNORE_ARGS[@]+"${IGNORE_ARGS[@]}"} "$DB" > "$DB_DUMP"

if [[ ${#SKIP_TABLES[@]} -gt 0 ]]; then
  # Structure (+ triggers) only for the skipped tables. Loaded FIRST so views
  # in the main dump that reference them can be created; the dump disables
  # FOREIGN_KEY_CHECKS itself, so FK order doesn't matter.
  info "Dumping structure only for: ${SKIP_TABLES[*]}…"
  "$DUMP_BIN" --defaults-extra-file="$SRC_CNF" \
    --no-data --triggers --skip-routines --skip-events \
    --set-gtid-purged=OFF --no-tablespaces \
    "$DB" "${SKIP_TABLES[@]}" > "$SCHEMA_ONLY_DUMP"
  info "Loading structure-only tables into '$DST_DB'…"
  "$MYSQL_BIN" --defaults-extra-file="$DST_CNF" "$DST_DB" < "$SCHEMA_ONLY_DUMP"
fi

info "Loading into target database '$DST_DB'…"
"$MYSQL_BIN" --defaults-extra-file="$DST_CNF" "$DST_DB" < "$DB_DUMP"

# Make sure the replayed grants are active.
dst_q "FLUSH PRIVILEGES" || true

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
src_tables="$(src_q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DBQ' AND TABLE_TYPE='BASE TABLE'")"
dst_tables="$(dst_q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(sql_quote "$DST_DB")' AND TABLE_TYPE='BASE TABLE'")"

info "Base-table count — source: $src_tables, target: $dst_tables"
if [[ "$src_tables" == "$dst_tables" ]]; then
  info "Migration complete. Database '$DST_DB' now on $DST_HOST."
else
  info "WARNING: table counts differ. Re-run with --keep-dumps and inspect $DB_DUMP."
  exit 2
fi
