#!/bin/bash
# roll.sh — roll a GKOI media box to the release its SSM config now names, in place, over SSM (no new instance).
#
#   roll.sh [--drain-wait MINUTES] [--force] [--dry-run]
#
# A release = commit envs/prod2/releases/mikaido.json (tools/gkoi-release) → apply the media stack (it rewrites
# /gkoi/prod2/media/<key>/config: the image digests, the engine source.zip, the box bundle) → run this on the box:
#
#   aws ssm send-command --region <r> --document-name AWS-RunShellScript \
#     --targets Key=tag:aws:autoscaling:groupName,Values=gkoi-prod2-media-<key> \
#     --parameters 'commands=["/opt/gkoi-media/roll.sh --drain-wait 60"]' --timeout-seconds 7200
#
# Steps:
#   1. media-bootstrap.sh apply --only config: the new config + bundle + the engine's config files (sha256-checked);
#   2. `render`: the new compose file (shown by --dry-run against the running one);
#   3. the gate: the box is DRAINED for the roll (POST /drain: no new sessions here — with one box per region the
#      region takes none meanwhile); an idle box rolls at once, a busy one (sessions / recordings / builds) waits up to
#      --drain-wait N minutes for idle; still busy after N minutes → the drain is cleared and the roll refused (exit 3), unless --force (cuts
#      every live stream on the box);
#   3b. (1.1.8) ONLY when the config names the automatic ingest host (agent_env.INGEST_AUTO_HOST): the box stays drained
#      at least --dns-drain-wait SECONDS (default 300, 0 = off) counted FROM THE DRAIN before anything restarts, so its
#      IngestAccepting alarm (2 of 3 minutes) has failed the Route 53 health check and the TTL (60 s) has run out —
#      new automatic senders already go elsewhere (SPEC-ONE-INGEST-ADDRESS-V1 §14.6). Not a second wait: the time spent
#      in step 3's --drain-wait (waiting for idle) counts toward it; only the remainder is slept. No agent running = no
#      drain = no wait (the metric is already missing, i.e. breaching);
#   4. media-bootstrap.sh apply --only certs,env,compose,lifecycle (a new stream/origin name gets its cert first) — its
#      output is also appended to /var/log/gkoi-media-bootstrap.log (→ CloudWatch …/bootstrap, where the cert-failure
#      metric filter reads a failed re-issue);
#   5. the drain cleared, `check` printed.
# --dry-run: steps 1–2 only, then print what would change.
set -euo pipefail
# SSM Run Command starts with no HOME and the agent's snap directory as cwd; the aws CLI and docker want both sane.
export HOME="${HOME:-/root}"; cd /
GKOI_MEDIA_WHO=roll
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=media-lib.sh
. "$HERE/media-lib.sh"

wait_min=0 force=0 dry=0 dns_wait=300
while [ $# -gt 0 ]; do
  case "$1" in
    --drain-wait) wait_min="${2:-}"; shift 2 ;;
    --dns-drain-wait) dns_wait="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: roll.sh [--drain-wait MINUTES] [--dns-drain-wait SECONDS] [--force] [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ "$wait_min" =~ ^[0-9]+$ ]] || die "--drain-wait needs whole minutes"
[[ "$dns_wait" =~ ^[0-9]+$ ]] || die "--dns-drain-wait needs whole seconds"
[ "$(id -u)" -eq 0 ] || die "run as root (SSM runs as root)"

say "== roll $(date -u +%FT%TZ): $(cfg .engine_source.tag) → refreshing the config"
"$TOOL/media-bootstrap.sh" apply --only config
say "now: engine $(cfg .engine_source.tag), agent $(cfg '.images["media-agent"]'), pools $(cfg .images.mediamtx)"

new="$(mktemp)"; trap 'rm -f "$new"' EXIT
"$TOOL/media-bootstrap.sh" render > "$new"
changed=""
[ -f "$COMPOSE_FILE" ] && cmp -s "$new" "$COMPOSE_FILE" || changed+=" compose"
# The env files depend on secrets too: a rotated secret is a change. Compare the plain parts only (never print values).
for k in stream_host origin_host portal_internal_url pool_count; do
  [ "$(jq -r ".$k" "$CFG")" = "$(jq -r ".$k" "$STATE/last-roll.json" 2>/dev/null || true)" ] || changed+=" $k"
done
if [ $dry -eq 1 ]; then
  say "dry run: would change:${changed:- nothing in the compose file or the box names} (env-file values — secrets — are compared by compose itself at up)"
  [ -f "$COMPOSE_FILE" ] && diff -u "$COMPOSE_FILE" "$new" || true
  exit 0
fi

# Drain for the roll even when idle: no session may be placed here while the containers are recreated.
drained_by_us=0
undrain() { [ $drained_by_us -eq 1 ] && { agent_call DELETE /drain >/dev/null || warn "the drain could not be cleared — DELETE /drain on the agent (or the engine admin)"; }; drained_by_us=0; }
# A failed roll (a die anywhere below) must not leave the region drained.
trap 'rm -f "$new"; undrain' EXIT
drained_at=0
if [ -n "$(container_of media-agent)" ]; then
  agent_call POST /drain >/dev/null || die "the agent refused the drain"
  drained_by_us=1
  drained_at=$(date +%s)
fi
if ! box_idle; then
  if [ "$force" -eq 1 ]; then
    say "busy, --force: rolling NOW (every live stream on this box is cut): $(box_report)"
  elif [ "$wait_min" -gt 0 ]; then
    say "busy: drained, waiting up to $wait_min min: $(box_report)"
    end=$(( $(date +%s) + wait_min * 60 ))
    until box_idle; do
      if [ "$(date +%s)" -ge "$end" ]; then
        undrain
        say "still busy after $wait_min min — roll REFUSED, drain cleared: $(box_report)"
        exit 3
      fi
      sleep 20
    done
    say "idle: rolling"
  else
    undrain
    die "the box is busy ($(box_report)): pass --drain-wait MINUTES (or --force to cut the streams)"
  fi
fi

# 3b. The automatic name (1.1.8): stay drained until Route 53 has dropped this box (counted from the drain).
auto_host="$(cfg_or '.agent_env.INGEST_AUTO_HOST' '')"
if [ -n "$auto_host" ] && [ $drained_by_us -eq 1 ] && [ "$dns_wait" -gt 0 ]; then
  left=$(( drained_at + dns_wait - $(date +%s) ))
  if [ $left -gt 0 ]; then
    say "automatic name $auto_host: drained — waiting ${left} s more so Route 53 drops this box before anything restarts (--dns-drain-wait $dns_wait)"
    sleep "$left"
  fi
fi

# 4. Appended to the bootstrap log too: CloudWatch …/bootstrap (the cert-failure metric filter) sees a failed re-issue.
say "== roll: certs, env, compose, lifecycle $(date -u +%FT%TZ)" | tee -a /var/log/gkoi-media-bootstrap.log
GKOI_MEDIA_FORCE=1 "$TOOL/media-bootstrap.sh" apply --only certs,env,compose,lifecycle 2>&1 | tee -a /var/log/gkoi-media-bootstrap.log
undrain
jq '{stream_host, origin_host, portal_internal_url, pool_count, engine: .engine_source.tag}' "$CFG" > "$STATE/last-roll.json"
"$TOOL/media-bootstrap.sh" check || die "rolled, but the check is not clean (above)"
say "== rolled to $(cfg .engine_source.tag)"
