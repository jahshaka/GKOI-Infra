# tools/lib/gkoi-tools.sh: shared by gkoi-release, gkoi-tag and gkoi-infra-run (sourced, never run).
# AWS goes through ~/.local/bin/gkoi-aws (Roles Anywhere, role /gkoi/gkoi-orchestrator, fresh 1-hour creds per call).
# gkoi-aws runs the AWS CLI in Docker with ONLY the current directory mounted (at /aws), so every call here runs from
# the tool's work directory and passes file paths relative to it.

GKOI_INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GKOI_WORKSPACE="${GKOI_WORKSPACE:-$(dirname "$GKOI_INFRA")}"
GKOI_ACCOUNT=127214190346
GKOI_REGION=us-west-2
GKOI_BUCKET="gkoi-build-sources-$GKOI_ACCOUNT"
GKOI_AWS="${GKOI_AWS:-$HOME/.local/bin/gkoi-aws}"
GKOI_POLL_SECONDS="${GKOI_POLL_SECONDS:-15}"
# Used by the tools that source this file.
# shellcheck disable=SC2034
GKOI_TAG_RE='^gkoi-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]+$'
# shellcheck disable=SC2034
GKOI_WARROOM_TAG_RE='^[0-9]+(\.[0-9]+){2,4}[a-z]?(-h[0-9]+)?$'
# shellcheck disable=SC2034
GKOI_APP_REPOS="aisolver-www mikaido filemanager"
export AWS_DEFAULT_REGION="$GKOI_REGION"

say() { printf '%s: %s\n' "${GKOI_TOOL:-gkoi}" "$*"; }
die() { printf '%s: ERROR: %s\n' "${GKOI_TOOL:-gkoi}" "$*" >&2; exit 1; }
# Print a command the way it would be run (dry runs and the "next step" hints).
show() { printf '  $'; printf ' %q' "$@"; printf '\n'; }

# Run gkoi-aws from the work directory (GKOI_WORK), stdin closed (it runs `docker run -i`).
awsc() {
  [ -n "${GKOI_WORK:-}" ] || die "awsc: GKOI_WORK is not set"
  [ -x "$GKOI_AWS" ] || die "no $GKOI_AWS (the fallback AWS access)"
  (cd "$GKOI_WORK" && "$GKOI_AWS" "$@" </dev/null)
}

repo_dir() {
  case "$1" in
    aisolver-www|mikaido|filemanager) printf '%s\n' "$GKOI_WORKSPACE/$1" ;;
    warroom-game) printf '%s\n' "$GKOI_WORKSPACE" ;;   # GKOIBuilder_AI: ops/warroom-game
    *) die "unknown repo '$1' (aisolver-www | mikaido | filemanager | warroom-game)" ;;
  esac
}

# Prints the first release-line ref (main, origin/main, hotfix/*) the commit is reachable from; fails if none.
release_line_of() { # <dir> <commit>
  local d="$1" c="$2" ref
  while IFS= read -r ref; do
    if git -C "$d" merge-base --is-ancestor "$c" "$ref" 2>/dev/null; then printf '%s\n' "$ref"; return 0; fi
  done < <(git -C "$d" for-each-ref --format='%(refname)' refs/heads/main refs/remotes/origin/main \
             refs/heads/hotfix/ refs/remotes/origin/hotfix/)
  return 1
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
zip_comment() { python3 -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).comment.decode())' "$1"; }
zip_file_count() { unzip -Z1 "$1" | grep -vc '/$'; }

# s3 object state: prints "present", "absent", or dies on any other answer (no rights, network).
s3_state() { # <key>
  local out rc=0
  out="$(awsc s3api head-object --bucket "$GKOI_BUCKET" --key "$1" 2>&1)" || rc=$?
  if [ $rc -eq 0 ]; then echo present; return 0; fi
  case "$out" in *"(404)"*|*"Not Found"*) echo absent ;; *) die "cannot check s3://$GKOI_BUCKET/$1: $out" ;; esac
}

# Upload <file> (relative to GKOI_WORK) to <key>: through gkoi-aws, or a presigned PUT URL read from <url file>.
upload() { # <file> <key> [<url file>]
  local f="$1" key="$2" urlf="${3:-}" url
  if [ -n "$urlf" ]; then
    [ -r "$urlf" ] || die "cannot read the presigned URL file $urlf"
    url="$(head -n1 "$urlf" | tr -d '\r\n')"
    [[ "$url" == https://* ]] || die "$urlf does not hold an https URL"
    say "upload $f → presigned PUT (s3://$GKOI_BUCKET/$key)"
    curl -fsS --retry 3 -X PUT -T "$GKOI_WORK/$f" "$url" -o /dev/null || die "the presigned PUT of $f failed"
  else
    say "upload $f → s3://$GKOI_BUCKET/$key"
    awsc s3 cp --no-progress "$f" "s3://$GKOI_BUCKET/$key" >/dev/null || die "the upload of $f failed"
  fi
}

# Start a CodeBuild build from <json file> (relative to GKOI_WORK); prints the build id.
cb_start() {
  local id
  id="$(awsc codebuild start-build --cli-input-json "file://$1" --query build.id --output text)" \
    || die "start-build failed"
  [[ "$id" == *:* ]] || die "start-build returned no build id: $id"
  printf '%s\n' "$id"
}

# Print the last <n> lines of a build's CloudWatch log.
cb_tail() { # <group> <stream> <n>
  if [ -z "$1" ] || [ -z "$2" ]; then say "(no log stream for this build)"; return 0; fi
  awsc logs get-log-events --log-group-name "$1" --log-stream-name "$2" --limit "$3" --output json \
    | jq -r '.events[].message' | sed 's/[[:space:]]*$//' || say "(could not read the log)"
}

# Wait for a build. Prints phase changes; with stream=1 also prints the log as it grows. On failure prints the
# log's last 120 lines and returns 1.
cb_wait() { # <build id> <stream 0|1>
  local id="$1" stream="$2" j status phase last_phase="" group="" lstream="" token="" next ev
  while :; do
    j="$(awsc codebuild batch-get-builds --ids "$id" --output json)" || { say "(poll failed, retrying)"; sleep "$GKOI_POLL_SECONDS"; continue; }
    status="$(jq -r '.builds[0].buildStatus' <<<"$j")"
    phase="$(jq -r '.builds[0].currentPhase' <<<"$j")"
    group="$(jq -r '.builds[0].logs.groupName // empty' <<<"$j")"
    lstream="$(jq -r '.builds[0].logs.streamName // empty' <<<"$j")"
    if [ "$phase" != "$last_phase" ]; then say "phase $phase ($(date -u +%H:%M:%S)Z)"; last_phase="$phase"; fi
    if [ "$stream" = 1 ] && [ -n "$group" ] && [ -n "$lstream" ]; then
      while :; do
        if [ -n "$token" ]; then
          ev="$(awsc logs get-log-events --log-group-name "$group" --log-stream-name "$lstream" --start-from-head \
                 --next-token "$token" --output json 2>/dev/null)" || break
        else
          ev="$(awsc logs get-log-events --log-group-name "$group" --log-stream-name "$lstream" --start-from-head \
                 --output json 2>/dev/null)" || break
        fi
        jq -r '.events[].message' <<<"$ev" | sed 's/[[:space:]]*$//'
        next="$(jq -r '.nextForwardToken' <<<"$ev")"
        [ "$next" != "$token" ] || break
        token="$next"
      done
    fi
    case "$status" in
      IN_PROGRESS) sleep "$GKOI_POLL_SECONDS" ;;
      SUCCEEDED) say "build $id SUCCEEDED"; return 0 ;;
      *)
        say "build $id ended $status; the phases:"
        jq -r '.builds[0].phases[] | "  \(.phaseType) \(.phaseStatus // "-") \((.contexts // []) | map(.message // "") | join(" "))"' <<<"$j"
        if [ "$stream" != 1 ]; then say "the log's last 120 lines:"; cb_tail "$group" "$lstream" 120; fi
        return 1 ;;
    esac
  done
}
