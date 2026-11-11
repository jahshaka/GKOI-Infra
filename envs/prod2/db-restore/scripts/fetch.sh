#!/bin/bash
# The db-restore task's FIRST container ("fetch", image gkoi/aws-cli): download the dump + its .sha256 sidecar from
# the transit bucket into the task's shared /work volume, verify the sha256, and leave the app role's password in
# /work/app.pw for the "restore" container. The task role reaches ONLY this app's prefix and this app's password secret.
#
# Environment (task definition): APP, BUCKET, PW_SECRET_ID (the secret's NAME, gkoi/prod2/<app>/<NAME>)
#   overrides (tools/gkoi-db-restore): DUMP_KEY (<app>/<stamp>/<db>.dump), DUMP_SHA256 (optional: must match too),
#   GENERATE_PASSWORD (0 = default: READ the secret, refuse an empty one; 1 = an EMPTY secret gets a new
#   48-character alphanumeric password — needs the stack's allow_generate_password = true)
# Never prints a secret value. Exit: 0 ok · 2 bad input · 3 dump missing / sha mismatch · 4 password secret problem.
set -euo pipefail

say() { printf 'fetch: %s\n' "$*"; }
die() { local c="$1"; shift; printf 'fetch: ERROR: %s\n' "$*" >&2; exit "$c"; }

WORK="${WORK:-/work}"
: "${APP:?APP is not set}" "${BUCKET:?BUCKET is not set}" "${PW_SECRET_ID:?PW_SECRET_ID is not set}"
key="${DUMP_KEY:-}"
want_override="${DUMP_SHA256:-}"
gen="${GENERATE_PASSWORD:-0}"

[ -n "$key" ] || die 2 "DUMP_KEY is not set (tools/gkoi-db-restore passes it as a container override)"
case "$key" in "$APP"/*) ;; *) die 2 "DUMP_KEY must start with '$APP/' (got '$key')" ;; esac
if ! [[ "$key" =~ ^[A-Za-z0-9._/-]+\.dump$ ]] || [[ "$key" == *..* ]]; then
  die 2 "DUMP_KEY '$key' is not <app>/<stamp>/<name>.dump"
fi
if [ -n "$want_override" ] && ! [[ "$want_override" =~ ^[0-9a-f]{64}$ ]]; then die 2 "DUMP_SHA256 is not 64 hex characters"; fi
case "$gen" in 0 | 1) ;; *) die 2 "GENERATE_PASSWORD must be 0 or 1" ;; esac

umask 077
mkdir -p "$WORK"
rm -f "$WORK/db.dump" "$WORK/db.dump.sha256" "$WORK/app.pw" "$WORK/app.pw.state" "$WORK/fetch.ok"

# --- the dump ----------------------------------------------------------------------------------------------------
say "s3://$BUCKET/$key"
aws s3 cp --no-progress --only-show-errors "s3://$BUCKET/$key" "$WORK/db.dump" || die 3 "cannot download s3://$BUCKET/$key"
aws s3 cp --no-progress --only-show-errors "s3://$BUCKET/$key.sha256" "$WORK/db.dump.sha256" \
  || die 3 "cannot download the sidecar s3://$BUCKET/$key.sha256"
want="$(awk 'NR == 1 { print $1 }' "$WORK/db.dump.sha256")"
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || die 3 "the sidecar $key.sha256 holds no sha256"
if [ -n "$want_override" ] && [ "$want_override" != "$want" ]; then
  die 3 "the sidecar's sha256 ($want) is not the one the tool expected ($want_override)"
fi
got="$(sha256sum "$WORK/db.dump" | cut -d' ' -f1)"
[ "$got" = "$want" ] || die 3 "sha256 MISMATCH: the object is $got, the sidecar says $want"
[ "$(head -c 5 "$WORK/db.dump")" = PGDMP ] || die 3 "$key is not a pg_dump custom-format archive (no PGDMP magic)"
say "sha256 ok $got ($(stat -c %s "$WORK/db.dump") bytes)"

# --- the app role's password ---------------------------------------------------------------------------------------
# A secret the compute stack created EMPTY has no AWSCURRENT version: get-secret-value answers ResourceNotFound for it,
# exactly as for a secret that does not exist — describe-secret tells the two apart.
aws secretsmanager describe-secret --secret-id "$PW_SECRET_ID" --query Name --output text >/dev/null 2>"$WORK/err" \
  || die 4 "the secret $PW_SECRET_ID does not exist or is not readable (apply the compute stack first): $(head -c 300 "$WORK/err")"

state=existing
if ! pw="$(aws secretsmanager get-secret-value --secret-id "$PW_SECRET_ID" --query SecretString --output text 2>"$WORK/err")"; then
  if ! grep -q ResourceNotFoundException "$WORK/err"; then
    die 4 "cannot read $PW_SECRET_ID: $(head -c 300 "$WORK/err")"
  fi
  [ "$gen" = 1 ] || die 4 "$PW_SECRET_ID has no value and GENERATE_PASSWORD=0 (put one, or gkoi-db-restore --generate-password with allow_generate_password = true)"
  pw="$(aws secretsmanager get-random-password --password-length 48 --exclude-punctuation --require-each-included-type \
          --query RandomPassword --output text)" || die 4 "get-random-password failed"
  printf '%s' "$pw" > "$WORK/app.pw.new"
  # file:// keeps the value off this process's argv; the token makes a retried put idempotent.
  aws secretsmanager put-secret-value --secret-id "$PW_SECRET_ID" --secret-string "file://$WORK/app.pw.new" \
    --client-request-token "$(cat /proc/sys/kernel/random/uuid)" --query VersionId --output text >/dev/null 2>"$WORK/err" \
    || { rm -f "$WORK/app.pw.new"; die 4 "put-secret-value on $PW_SECRET_ID failed: $(head -c 300 "$WORK/err")"; }
  rm -f "$WORK/app.pw.new"
  # Read it back: the value the services will be given is the one stored, whatever happened above.
  pw="$(aws secretsmanager get-secret-value --secret-id "$PW_SECRET_ID" --query SecretString --output text 2>"$WORK/err")" \
    || die 4 "cannot read back $PW_SECRET_ID: $(head -c 300 "$WORK/err")"
  state=generated
fi
rm -f "$WORK/err"
case "$pw" in *$'\n'* | *$'\r'*) die 4 "$PW_SECRET_ID holds a line break — store the bare password (no trailing newline)" ;; esac
[ "${#pw}" -ge 16 ] || die 4 "$PW_SECRET_ID holds fewer than 16 characters"
[ "$pw" != None ] || die 4 "$PW_SECRET_ID holds no SecretString (binary secret?)"
printf '%s' "$pw" > "$WORK/app.pw"
unset pw
printf '%s\n' "$state" > "$WORK/app.pw.state"
say "password: $state in $PW_SECRET_ID (length only: $(stat -c %s "$WORK/app.pw"))"

# The restore container reads /work as root (the postgres image's default user); 0600 root-owned is enough.
touch "$WORK/fetch.ok"
say "FETCH_OK $APP $got"
