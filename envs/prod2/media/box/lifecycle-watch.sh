#!/bin/bash
# lifecycle-watch.sh — the ASG terminate hook on a GKOI media box (gkoi-media-lifecycle.service, installed by
# media-bootstrap.sh phase lifecycle). Every 15 s it reads IMDS autoscaling/target-lifecycle-state; when the ASG moves
# this box to Terminating:Wait (target "Terminated") it:
#   1. drains the box through the agent's own endpoint (POST /drain: no new sessions / vod jobs placed here — the engine's
#      registry flag, SPEC-PLATFORM-AWS-READY-V1 A3);
#   2. waits until the agent reports idle (no sessions, recordings uploaded, builds done) or drain_max_minutes pass,
#      renewing the hook's heartbeat every 5 minutes;
#   3. stops the stack (the agent's heartbeat stops → its pools leave the registry within 30 s);
#   4. completes the lifecycle action with CONTINUE.
# The hook's own default is CONTINUE, so a dead box (or a dead watcher) never blocks a termination.
set -uo pipefail
GKOI_MEDIA_WHO=lifecycle
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=media-lib.sh
. "$HERE/media-lib.sh"

while :; do
  state="$(imds meta-data/autoscaling/target-lifecycle-state 2>/dev/null || true)"
  [ "$state" = Terminated ] && break
  sleep 15
done

region="$(own_region)"; iid="$(instance_id)"; asg="$(cfg .asg_name)"; hook="$(cfg .lifecycle_hook)"
max_min="$(cfg_or .drain_max_minutes 120)"
say "terminating: draining $(box_id) (up to $max_min min)"
agent_call POST /drain >/dev/null 2>&1 || say "drain: the agent did not answer (not running?)"
start=$(date +%s); last_beat=$start
while :; do
  if box_idle; then say "idle: $(box_report)"; break; fi
  now=$(date +%s)
  if [ $((now - start)) -ge $((max_min * 60)) ]; then say "drain window over, letting go anyway: $(box_report)"; break; fi
  if [ $((now - last_beat)) -ge 300 ]; then
    aws autoscaling record-lifecycle-action-heartbeat --region "$region" --auto-scaling-group-name "$asg" \
      --lifecycle-hook-name "$hook" --instance-id "$iid" >/dev/null 2>&1 || say "heartbeat failed"
    last_beat=$now
  fi
  sleep 20
done
[ -f "$COMPOSE_FILE" ] && compose stop --timeout 60 >/dev/null 2>&1
if aws autoscaling complete-lifecycle-action --region "$region" --auto-scaling-group-name "$asg" \
  --lifecycle-hook-name "$hook" --instance-id "$iid" --lifecycle-action-result CONTINUE >/dev/null; then
  say "lifecycle action completed (CONTINUE)"
else
  say "complete-lifecycle-action failed (the hook times out to CONTINUE)"
fi
# Stay up (systemd would restart us into the loop again); the instance is going away.
sleep infinity
