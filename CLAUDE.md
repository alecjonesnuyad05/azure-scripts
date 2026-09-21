# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

A scratch/working folder for DevOps scripts under the broader `devops` workspace (`../`), which contains related operational work: cloud provisioning (`../azure`, `../terraform-test`), server migrations (`../migration`, `../bornhetzner*`), monitoring (`../monitoring`, `../ohdear`, `../securityheaders`), deployment tooling (`../pydeploy`), and security scanning (`../nuclei_3.11.0_windows_amd64`).

## Scripts

### `pg_migrate_db.sh`

Migrates a single PostgreSQL database from one server to another **using admin
credentials**, and carries the database's owning role (the "custom user") across
with it — including the encrypted password hash, so the password is preserved
without ever appearing in plaintext.

Flow: connect to source as admin → auto-detect the DB owner → dump that role
via `pg_dumpall --roles-only` (filtered to the one role) → recreate it on the
target (skipped if it already exists, unless `--force-role`) → create the target
DB owned by that role → `pg_dump -Fc` / `pg_restore` the contents → verify table
counts match.

**Run:**
```bash
export SRC_PGPASSWORD='...'   # source admin password (or use ~/.pgpass)
export DST_PGPASSWORD='...'   # target admin password
./pg_migrate_db.sh --db mydb \
    --src-host born1 --src-admin postgres \
    --dst-host born3 --dst-admin postgres \
    [--dst-db newname] [--force-role] [--drop-existing] [--keep-dumps] [--dry-run]
```
`--help` prints full usage. `--dry-run` runs all the read-only checks (connectivity,
DB existence, owner detection, role dump, whether the role/target DB already
exist) and prints exactly what would happen, without creating/altering any
role or database and without dumping/restoring anything.

**Config via env file:** on startup the script auto-loads `.env.pg` (preferred)
or `.env` from its own directory (override with `ENV_FILE=/path/file`). Any
variable set there (`SRC_PGPASSWORD`, `DST_PGPASSWORD`, `SRC_HOST`, `DST_HOST`,
ports, admins, `DB`, `DST_DB`) becomes a default. Precedence: **CLI flags > env
file > built-in defaults.** Copy `.env.pg.example` to `.env.pg` to get started;
never commit the real file. Requires `psql`, `pg_dump`, `pg_dumpall`, `pg_restore`
on PATH. Run under Bash (the POSIX shell available here), not PowerShell.

**Lint/test:** `bash -n pg_migrate_db.sh` for a syntax check; `shellcheck
pg_migrate_db.sh` if available. There is no automated test suite — validate
against a throwaway/staging pair of servers before touching production
(`born1`, `born3`, `bornhetzner*`, `borndev`).

**Credentials:** never hardcoded. Admin passwords come from `SRC_PGPASSWORD` /
`DST_PGPASSWORD` (falling back to `PGPASSWORD`, then `~/.pgpass`). The custom
user's password is copied as its stored hash — the script neither reads nor sets
it in plaintext.

### `mysql_migrate_db.sh`

The MySQL/MariaDB counterpart to `pg_migrate_db.sh`. Migrates a single database
between servers **using admin credentials** and carries the database's user(s)
across too. MySQL has no DB "owner", so the "custom user" is every non-system
account holding privileges on that schema (via `mysql.db` / `tables_priv` /
`procs_priv`); each is recreated on the target from `SHOW CREATE USER` — which
preserves the existing password hash — and its grants scoped to that database
are replayed. Then it `mysqldump`s the data (matching charset/collation) and
loads it into a freshly created target DB, and verifies base-table counts.

**Run:**
```bash
export SRC_MYSQL_PWD='...'   # or use ~/.my.cnf / .env
export DST_MYSQL_PWD='...'
./mysql_migrate_db.sh --db mydb \
    --src-host born1 --src-admin root \
    --dst-host born3 --dst-admin root \
    [--dst-db newname] [--force-user] [--drop-existing] [--keep-dumps] [--dry-run]
```
`--help` prints full usage. `--dry-run` runs all the read-only checks
(connectivity, DB existence, which users hold privileges on it, whether the
target DB/users already exist) and prints exactly what would happen, without
creating/altering any user, replaying grants, or creating/dropping/loading
the database. Auto-loads `.env.mysql` (preferred) or `.env` from
its own directory; copy `.env.mysql.example` to `.env.mysql` to start.
Requires the `mysql`/`mariadb` client and `mysqldump`/`mariadb-dump` on PATH
(both naming schemes are auto-detected). Passwords are written to short-lived
`0600` option files and passed via `--defaults-extra-file`, never on the command
line (so they don't leak in `ps`).

**Lint/test:** `bash -n mysql_migrate_db.sh` / `shellcheck`. Same caveat: no
automated tests — validate against staging first.

### `azure_migrate_disk.sh`

Migrates an Azure managed VM disk from one subscription/tenant to another,
including **cross-tenant** (no AAD trust or cross-tenant RBAC required).
Managed-disk-to-disk copy (`az disk create --source <disk-id>`) only works
within a single tenant, so this script instead moves the bytes over plain
HTTPS using SAS tokens (storage-account-scoped, tenant-agnostic): it snapshots
the source disk, grants a time-limited read SAS on the snapshot, stages a
storage account + container in the destination, `azcopy`s SAS-to-SAS into it,
then creates the destination managed disk from that staged blob.

Flow: log into source sub → snapshot source disk → grant read SAS on
snapshot → log into destination sub → create/reuse staging storage account
→ `azcopy copy` (SAS-to-SAS, no tenant auth needed) → `az disk create
--source <staged blob>` → revoke/delete source snapshot, drop staged blob →
verify disk size matches.

**Run:**
```bash
export SRC_AZURE_CLIENT_SECRET='...'   # source SP secret (or reuse an existing `az login`)
export DST_AZURE_CLIENT_SECRET='...'   # destination SP secret
./azure_migrate_disk.sh --disk mydisk \
    --src-rg my-src-rg --src-subscription <src-sub-id> \
    --dst-rg my-dst-rg --dst-subscription <dst-sub-id> \
    [--dst-disk newname] [--dst-location westeurope] [--sku Premium_LRS] \
    [--staging-account name] [--drop-existing] [--keep-staging] [--dry-run]
```
`--help` prints full usage. `--dry-run` logs into both sides, reads the
source disk's size/sku/location, checks whether the destination disk
already exists, and prints exactly what would happen, without creating a
snapshot/SAS/staging account, running azcopy, or creating/deleting the
destination disk.

**Config via env file:** on startup the script auto-loads `.env.azure`
(preferred) or `.env` from its own directory (override with
`ENV_FILE=/path/file`). Precedence: **CLI flags > env file > built-in
defaults.** Copy `.env.azure.example` to `.env.azure` to get started; never
commit the real file. Requires `az` (Azure CLI) and `azcopy` on PATH. Run
under Bash, not PowerShell.

**Consistency note:** a snapshot of a disk attached to a running VM is
crash-consistent, not application-consistent. For a clean copy, stop/
deallocate the source VM first — the script does not do this for you.

**Lint/test:** `bash -n azure_migrate_disk.sh` / `shellcheck`. No automated
test suite — validate against a throwaway disk/subscription first. This is
the DevOps-scripts counterpart to `../azure`'s provisioning tooling, for the
case where a VM disk needs to move between tenants (e.g. a client tenant
migration), not just between resource groups in the same tenant.

**Credentials:** never hardcoded. Service principal secrets come from
`SRC_AZURE_CLIENT_SECRET` / `DST_AZURE_CLIENT_SECRET` (plus matching
`_TENANT_ID` / `_CLIENT_ID`); if unset for a side, the script skips `az
login` for it and expects that subscription to already be usable via an
existing `az login` session.

### `azure_migrate_container.sh`

Copies an Azure Storage blob container from one storage account/subscription/
tenant to another (cross-tenant safe), using the same SAS-to-SAS approach as
`azure_migrate_disk.sh` — no cross-tenant RBAC or AAD trust required.

Flow: log into source sub → grant a read+list SAS on the source container →
log into destination sub → create/reuse the destination storage account +
container → grant a write+create SAS on it → `azcopy copy --recursive`
(SAS-to-SAS) → verify blob counts match.

**Run:**
```bash
export SRC_AZURE_CLIENT_SECRET='...'   # source SP secret (or reuse an existing `az login`)
export DST_AZURE_CLIENT_SECRET='...'   # destination SP secret
./azure_migrate_container.sh --container mycontainer \
    --src-account srcstorage --src-rg my-src-rg --src-subscription <src-sub-id> \
    --dst-account dststorage --dst-rg my-dst-rg --dst-subscription <dst-sub-id> \
    [--dst-container newname] [--dst-location westeurope] [--dst-sku Standard_LRS] \
    [--drop-existing] [--dry-run]
```
`--help` prints full usage. `--dry-run` authenticates both sides, reads the
source blob count, checks whether the destination account/container already
exist, and prints exactly what would happen, without granting a SAS,
creating an account/container, running azcopy, or deleting blobs. Shares
`.env.azure`/`.env` and the
`SRC_AZURE_*`/`DST_AZURE_*` service-principal env vars with
`azure_migrate_disk.sh` (same precedence: CLI flags > env file > defaults).
Requires `az` and `azcopy` on PATH. Run under Bash, not PowerShell.

**Alternative auth — storage account key:** pass `--src-account-key`/
`--dst-account-key` (or `SRC_ACCOUNT_KEY`/`DST_ACCOUNT_KEY`) to skip `az
login` and `--src-rg`/`--src-subscription` (or `dst-`) entirely for that
side — container-level operations only need the account key, not an AAD
session. The account itself must already exist on that side (creating one
is a management-plane operation and still needs a login). An account key
grants full read/write on the *entire* storage account, not just the one
container, so it's a bigger blast radius if leaked than the scoped,
time-limited SAS/service-principal path — prefer service-principal auth
when you can.

**Note:** blob-count verification assumes the destination container was
empty (or `--drop-existing` was used) before the copy — copying into a
non-empty container without `--drop-existing` will make the counts diverge
even on a successful copy.

**Lint/test:** `bash -n azure_migrate_container.sh` / `shellcheck`. No
automated test suite — validate against throwaway containers first.

## Environment

- Windows 11; primary shell is PowerShell. A Bash (POSIX) shell is also available — use the syntax matching whichever you invoke.
- Not a git repository at this level.

## Guidance for future work

When scripts are added here, update this file with:
- How to run, lint, and test them (including running a single test).
- The big-picture purpose and how these scripts relate to the sibling folders in `../` (which server/environment each targets: e.g. `born1`, `born3`, `bornhetzner*`, `borndev`).
- Any required credentials, environment variables, or target hosts — reference where they come from, never hardcode secrets.
