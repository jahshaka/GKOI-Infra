#!/bin/sh
# The ops-psql task's ONE container ("psql", image gkoi/ci-postgres = postgres:16.15-alpine): runs ONE SQL script
# against ONE app database on RDS as that app's role, and writes the result to its log in a framed, base64 form that
# GKOIBuilder_AI scripts/session-tools/prod-psql.sh reassembles byte for byte.
#
# Environment (task definition): PGHOST PGPORT PGDATABASE PGUSER PGSSLMODE, PGPASSWORD (ECS secret: the app's own
#   password secret — never the RDS master), MAX_SECONDS (wall clock), STATEMENT_MS (per statement).
# Overrides (RunTask): RUN_ID (hex, echoed in the frame), SQL_GZ_B64 (the SQL, gzip + base64), SQL_SHA256 (of the
#   plain SQL), WRITE (0 = read only — the default; 1 = read/write), FIELD_SEP (one character, default "|").
#
# The SQL runs as `psql -X -q -t -A -1 -v ON_ERROR_STOP=1`: one transaction, stop at the first error (rolled back).
# WRITE=0 sets default_transaction_read_only=on — a seatbelt against a slip, NOT a fence: the app role owns its
# database, and SQL that says `SET TRANSACTION READ WRITE` is not stopped by it.
#
# The log (one line each; the payload lines are base64 in chunks of 3000 characters, empty output = no lines):
#   @@BEGIN <run id> db=<db> user=<role> write=<0|1> sql_bytes=<n>
#   @@OUT <base64 of psql's stdout>   …
#   @@ERR <base64 of psql's stderr>   …
#   @@END <run id> rc=<exit code>
# Never prints a secret, nor the SQL itself (only its size; the caller's SQL may carry a session hash).
# Exit: psql's own code (0 ok · 1 fatal · 2 connection lost · 3 script error), 124/143 the wall clock hit,
#   64 bad input (SQL missing / undecodable / sha256 mismatch, bad WRITE / FIELD_SEP / RUN_ID).
set -u

RUN_ID="${RUN_ID:-}"
W="${TMPDIR:-/tmp}/ops-psql.$$"

emit() { # <tag> <file>: the file as base64, 3000 characters a line, each line "@@<tag> <chunk>"
  { base64 -w 0 <"$2"; echo; } | fold -w 3000 | sed -n "/./s/^/@@$1 /p"
}
finish() { # <rc>
  echo "@@END ${RUN_ID:-none} rc=$1"
  rm -rf "$W"
  exit "$1"
}
bad() { # <message>: a framed input error (64)
  printf 'ops-psql: %s\n' "$1" >"$W/err"
  : >"$W/out"
  emit ERR "$W/err"
  finish 64
}

if ! { mkdir -p "$W" && chmod 700 "$W"; }; then echo "@@END ${RUN_ID:-none} rc=70"; exit 70; fi

case "$RUN_ID" in '' | *[!0-9a-f]*) RUN_ID=none; echo "@@BEGIN none"; bad "RUN_ID must be lowercase hex" ;; esac
printf '%s' "${SQL_GZ_B64:-}" | base64 -d 2>/dev/null | gunzip -c >"$W/q.sql" 2>/dev/null
echo "@@BEGIN $RUN_ID db=${PGDATABASE:-?} user=${PGUSER:-?} write=${WRITE:-0} sql_bytes=$(wc -c <"$W/q.sql" | tr -d ' ')"

[ -s "$W/q.sql" ] || bad "no SQL (SQL_GZ_B64 empty or not gzip+base64)"
got="$(sha256sum "$W/q.sql" | cut -c1-64)"
[ "$got" = "${SQL_SHA256:-}" ] || bad "the SQL's sha256 does not match SQL_SHA256 (truncated override?)"
WRITE="${WRITE:-0}"
case "$WRITE" in 0 | 1) ;; *) bad "WRITE must be 0 or 1" ;; esac
FIELD_SEP="${FIELD_SEP:-|}"
[ "${#FIELD_SEP}" -eq 1 ] || bad "FIELD_SEP must be one character"
MAX_SECONDS="${MAX_SECONDS:-300}"
STATEMENT_MS="${STATEMENT_MS:-120000}"
case "$MAX_SECONDS$STATEMENT_MS" in *[!0-9]*) bad "MAX_SECONDS / STATEMENT_MS must be integers" ;; esac
[ -n "${PGPASSWORD:-}" ] && [ -n "${PGHOST:-}" ] && [ -n "${PGDATABASE:-}" ] && [ -n "${PGUSER:-}" ] \
  || bad "PGHOST / PGDATABASE / PGUSER / PGPASSWORD must be set (the task definition)"

opts="-c statement_timeout=$STATEMENT_MS -c lock_timeout=10000 -c idle_in_transaction_session_timeout=60000"
[ "$WRITE" = 1 ] || opts="$opts -c default_transaction_read_only=on"
export PGOPTIONS="$opts" PGAPPNAME=gkoi-ops-psql PGCONNECT_TIMEOUT=15

timeout -s TERM "$MAX_SECONDS" psql -X -q -t -A -1 -v ON_ERROR_STOP=1 -F "$FIELD_SEP" -f "$W/q.sql" >"$W/out" 2>"$W/err"
rc=$?
emit OUT "$W/out"
emit ERR "$W/err"
finish "$rc"
