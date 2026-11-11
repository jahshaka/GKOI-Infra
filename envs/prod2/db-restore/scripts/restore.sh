#!/bin/sh
# The db-restore task's SECOND container ("restore", image gkoi/postgres = postgres:16-alpine): runs once "fetch"
# exited 0. Connects to RDS as the master user (ECS injects PGUSER / PGPASSWORD from the RDS-managed master secret),
# then, for ONE app:
#   1. the app role: created LOGIN when missing; re-asserted NOCREATEDB NOCREATEROLE INHERIT (+ NOSUPERUSER
#      NOREPLICATION NOBYPASSRLS only when the runner is a superuser — a CREATEROLE admin may not name them) with the
#      password fetch left in /work/app.pw; granted to the master WITH INHERIT, SET (PostgreSQL 16: a CREATEROLE
#      creator holds only ADMIN, and CREATE DATABASE … OWNER / pg_restore --role need SET).
#      This is the repos' own C-4 rule (mikaido + filemanager infra/postgres/app-role.sql, aisolver-www
#      scripts/db/owner-role.sql): ONE role per app, the OWNER of its database and of every object in it, no superuser.
#   2. the database: refused when it exists and holds relations, unless DROP_FIRST names it (rehearsals: DROP … WITH
#      (FORCE)); else created OWNER the role, TEMPLATE template0, UTF8, the collation below.
#   3. pg_restore --no-owner --no-acl --role=<role> --single-transaction --exit-on-error, minus the TOC entries a
#      non-superuser cannot (and need not) replay: the plpgsql extension + its comment, schema public + its comment.
#   4. as the role: every non-system schema owned by it, ANALYZE; then the proof — nothing in a user schema, nor the
#      database, owned by anyone else (extension members excepted) and the role not a superuser.
#   5. the role logs in with its password over TLS (what the services will do).
# Environment: DB_NAME, DB_ROLE, PGHOST, PGPORT, PGSSLMODE, PGUSER + PGPASSWORD (secrets), DB_LC_COLLATE, DB_LC_CTYPE;
#   override DROP_FIRST=<DB_NAME> (anything else = no drop).
# Never prints a secret. Exit: 0 ok · 2 bad input · 3 RDS unreachable · 4 database not empty · 5 restore failed ·
#   6 ownership proof failed · 7 the role cannot log in.
set -eu

say() { printf 'restore: %s\n' "$*"; }
die() { c="$1"; shift; printf 'restore: ERROR: %s\n' "$*" >&2; exit "$c"; }

WORK="${WORK:-/work}"
: "${DB_NAME:?DB_NAME is not set}" "${DB_ROLE:?DB_ROLE is not set}" "${PGHOST:?PGHOST is not set}"
: "${PGUSER:?PGUSER is not set (the master secret)}" "${PGPASSWORD:?PGPASSWORD is not set (the master secret)}"
DROP_FIRST="${DROP_FIRST:-}"
DB_LC_COLLATE="${DB_LC_COLLATE:-C}"
DB_LC_CTYPE="${DB_LC_CTYPE:-en_US.UTF-8}"

ident_ok() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$'; }
ident_ok "$DB_NAME" || die 2 "DB_NAME '$DB_NAME' is not a plain identifier"
ident_ok "$DB_ROLE" || die 2 "DB_ROLE '$DB_ROLE' is not a plain identifier"
[ "$DB_ROLE" != "$PGUSER" ] || die 2 "DB_ROLE is the master user — the app role must be a separate role"
case "$DB_NAME" in postgres | template0 | template1 | rdsadmin) die 2 "DB_NAME '$DB_NAME' is a system database" ;; esac
[ -f "$WORK/fetch.ok" ] || die 2 "fetch did not finish ($WORK/fetch.ok missing)"
[ -s "$WORK/db.dump" ] || die 2 "no dump in $WORK"
[ -s "$WORK/app.pw" ] || die 2 "no app password in $WORK"

export PGSSLMODE="${PGSSLMODE:-require}" PGCONNECT_TIMEOUT=10 PGAPPNAME=gkoi-db-restore
# The app password travels in the ENVIRONMENT only (psql \getenv) — never on an argv (`ps`), never in a log line.
APP_PW="$(cat "$WORK/app.pw")"
export APP_PW
rm -f "$WORK/app.pw"

q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }

# --- 0. reach RDS ------------------------------------------------------------------------------------------------
n=0
until pg_isready -q -d postgres -t 5; do
  n=$((n + 1))
  [ "$n" -lt 12 ] || die 3 "RDS at $PGHOST does not answer (12 tries) — the task's SG / subnets, or the instance"
  sleep 5
done
q -d postgres -c 'SELECT 1' >/dev/null || die 3 "cannot sign in to $PGHOST as the master user"
say "connected: $(q -d postgres -c "SELECT current_user || ' on PostgreSQL ' || current_setting('server_version') || ', ssl ' || CASE WHEN (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) THEN 'on' ELSE 'OFF' END")"

# --- 1. the role ---------------------------------------------------------------------------------------------------
q -d postgres -v r="$DB_ROLE" <<'SQL'
\getenv pw APP_PW
SELECT format('CREATE ROLE %I LOGIN', :'r')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'r') \gexec
SELECT rolsuper AS role_is_super FROM pg_roles WHERE rolname = :'r' \gset
\if :role_is_super
DO $$ BEGIN RAISE EXCEPTION 'db-restore: the app role is a superuser — refusing (name another role)'; END $$;
\endif
SELECT format('ALTER ROLE %I WITH LOGIN NOCREATEDB NOCREATEROLE INHERIT %s PASSWORD %L',
              :'r',
              CASE WHEN (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
                   THEN 'NOSUPERUSER NOREPLICATION NOBYPASSRLS' ELSE '' END,
              :'pw') \gexec
SELECT format('GRANT %I TO %I WITH INHERIT TRUE, SET TRUE', :'r', current_user)
 WHERE NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
   AND NOT (pg_has_role(current_user, :'r', 'SET') AND pg_has_role(current_user, :'r', 'USAGE')) \gexec
SQL
say "role $DB_ROLE: LOGIN, no superuser/createdb/createrole, password set from the secret"

# --- 2. the database -----------------------------------------------------------------------------------------------
exists="$(echo "SELECT count(*) FROM pg_database WHERE datname = :'d';" | q -d postgres -v d="$DB_NAME")"
if [ "$exists" = 1 ]; then
  if [ "$DROP_FIRST" = "$DB_NAME" ]; then
    say "DROP_FIRST: dropping database $DB_NAME (WITH FORCE: its sessions are ended)"
    echo "SELECT format('DROP DATABASE %I WITH (FORCE)', :'d') \gexec" | q -d postgres -v d="$DB_NAME"
    exists=0
  else
    rels="$(q -d "$DB_NAME" -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'")"
    if [ "$rels" != 0 ]; then
      die 4 "database $DB_NAME exists and holds $rels relation(s) — nothing changed. A rehearsal re-run: --drop-first"
    fi
    say "database $DB_NAME exists and is empty: restoring into it"
    echo "SELECT format('ALTER DATABASE %I OWNER TO %I', :'d', :'r') \gexec" | q -d postgres -v d="$DB_NAME" -v r="$DB_ROLE"
  fi
fi
if [ "$exists" = 0 ]; then
  echo "SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L LOCALE_PROVIDER libc LC_COLLATE %L LC_CTYPE %L',
                   :'d', :'r', 'UTF8', :'co', :'ct') \gexec" \
    | q -d postgres -v d="$DB_NAME" -v r="$DB_ROLE" -v co="$DB_LC_COLLATE" -v ct="$DB_LC_CTYPE"
  say "database $DB_NAME created (owner $DB_ROLE, UTF8, collate $DB_LC_COLLATE, ctype $DB_LC_CTYPE)"
fi

# --- 3. the restore ------------------------------------------------------------------------------------------------
pg_restore -l "$WORK/db.dump" > "$WORK/toc.all" || die 5 "pg_restore cannot read the archive's table of contents"
# A TOC line: "<id>; <catalog oid> <oid> <TYPE> <schema|-> <name> <owner>". Skipped: what a non-superuser cannot
# replay on RDS and what template0 already holds.
grep -Ev '^[0-9]+; [0-9]+ [0-9]+ (EXTENSION - plpgsql( |$)|COMMENT - EXTENSION plpgsql( |$)|SCHEMA - public( |$)|COMMENT - SCHEMA public( |$))' \
  "$WORK/toc.all" > "$WORK/toc.use" || true
total="$(grep -Ec '^[0-9]+;' "$WORK/toc.all" || true)"
kept="$(grep -Ec '^[0-9]+;' "$WORK/toc.use" || true)"
say "archive: $(grep -E '^;[[:space:]]+(Dumped from database version|Archive created at|Format)' "$WORK/toc.all" | sed 's/^;[[:space:]]*//' | tr '\n' ' ')"
say "restoring $kept of $total TOC entries as $DB_ROLE (single transaction)"
pg_restore --dbname="$DB_NAME" --no-owner --no-acl --role="$DB_ROLE" --single-transaction --exit-on-error \
  --use-list="$WORK/toc.use" "$WORK/db.dump" || die 5 "pg_restore FAILED — the transaction rolled back; $DB_NAME is empty"
say "pg_restore ok"

# --- 4. ownership + proof ------------------------------------------------------------------------------------------
out="$(q -d "$DB_NAME" -v r="$DB_ROLE" <<'SQL'
SELECT format('SET ROLE %I', :'r') \gexec
SELECT format('ALTER SCHEMA %I OWNER TO %I', n.nspname, :'r')
  FROM pg_namespace n
 WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
   AND pg_get_userbyid(n.nspowner) <> :'r'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid AND d.deptype = 'e') \gexec
-- the planner's statistics (pg_restore leaves none); the user tables only, so no "skipping pg_…" warnings
SELECT format('ANALYZE %I.%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'm') AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' \gexec
RESET ROLE;
CREATE TEMP VIEW leftover AS
  SELECT 'relation' AS kind, c.oid::regclass::text AS name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
     AND pg_get_userbyid(c.relowner) <> :'r'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
  UNION ALL
  SELECT 'routine', p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND pg_get_userbyid(p.proowner) <> :'r'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  UNION ALL
  SELECT 'type', t.oid::regtype::text FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND pg_get_userbyid(t.typowner) <> :'r'
     AND (t.typtype IN ('e', 'r', 'm', 'd') OR (t.typtype = 'c' AND (SELECT c.relkind FROM pg_class c WHERE c.oid = t.typrelid) = 'c'))
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype IN ('e', 'i'))
  UNION ALL
  SELECT 'schema', n.nspname::text FROM pg_namespace n
   WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND pg_get_userbyid(n.nspowner) <> :'r'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid AND d.deptype = 'e')
  UNION ALL
  SELECT 'database', datname::text FROM pg_database WHERE datname = current_database() AND pg_get_userbyid(datdba) <> :'r';
SELECT format('LEFTOVER %s %s', kind, name) FROM leftover;
SELECT format('SUMMARY tables=%s sequences=%s schemas=%s extensions=%s live_rows=%s',
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'),
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S' AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'),
  (SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace
    WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema'),
  (SELECT string_agg(extname || ':' || pg_get_userbyid(extowner), ',' ORDER BY extname) FROM pg_extension),
  (SELECT coalesce(sum(n_live_tup), 0) FROM pg_stat_user_tables));
SELECT CASE WHEN (SELECT count(*) FROM leftover) = 0 AND NOT (SELECT rolsuper FROM pg_roles WHERE rolname = :'r')
            THEN 'OWNER_OK' ELSE 'OWNER_FAILED' END;
SQL
)" || die 6 "the ownership step failed"
printf '%s\n' "$out" | sed 's/^/restore: /'
printf '%s\n' "$out" | grep -qx OWNER_OK || die 6 "objects are left owned by another role (LEFTOVER lines above)"

# --- 5. the role signs in with its password, over TLS --------------------------------------------------------------
who="$(PGUSER="$DB_ROLE" PGPASSWORD="$APP_PW" q -d "$DB_NAME" \
        -c "SELECT current_user || ' ssl=' || (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())")" \
  || die 7 "$DB_ROLE cannot sign in to $DB_NAME with the secret's password"
say "sign-in as the app role: $who"
unset APP_PW
rm -f "$WORK/toc.all" "$WORK/toc.use"
say "RESTORE_OK db=$DB_NAME role=$DB_ROLE"
