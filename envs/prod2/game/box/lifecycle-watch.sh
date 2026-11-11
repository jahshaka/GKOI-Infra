#!/bin/bash
# lifecycle-watch.sh — the ASG terminate hook on a GKOI game box (gkoi-game-lifecycle.service, installed by
# game-bootstrap.sh phase lifecycle). Every 15 s it reads IMDS autoscaling/target-lifecycle-state; when the ASG moves
# this box to Terminating:Wait (target "Terminated") it:
#   1. runs the War Room tool's OWN drain hook (ops/warroom-game/drain-hook.sh run: the retiring marker — nothing restarts
#      matchd after it —, POST /drain-and-exit: new matches refused, live ones finish, matchd exits 0), at most
#      drain_max_minutes, then --on-timeout stop (SIGTERM ends what is left);
#   2. renews the hook's heartbeat every 5 minutes while that runs;
#   3. completes the lifecycle action with CONTINUE.
# The hook's own default is CONTINUE, so a dead box (or a dead watcher) never blocks a termination.
set -uo pipefail
export HOME="${HOME:-/root}"; cd /
GKOI_GAME_WHO=lifecycle
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=game-lib.sh
. "$HERE/game-lib.sh"

while :; do
  state="$(imds meta-data/autoscaling/target-lifecycle-state 2>/dev/null || true)"
  [ "$state" = Terminated ] && break
  sleep 15
done

region="$(own_region)"; iid="$(instance_id)"; asg="$(cfg .asg_name)"; hook="$(cfg .lifecycle_hook)"
max_min="$(cfg_or .drain_max_minutes 130)"
say "terminating: draining matchd (up to $max_min min)"
"$WR/drain-hook.sh" --env "$BOX_ENV" run --timeout $((max_min * 60)) --on-timeout stop &
pid=$!
last_beat=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
  now=$(date +%s)
  if [ $((now - last_beat)) -ge 300 ]; then
    aws autoscaling record-lifecycle-action-heartbeat --region "$region" --auto-scaling-group-name "$asg" \
      --lifecycle-hook-name "$hook" --instance-id "$iid" >/dev/null 2>&1 || say "heartbeat failed"
    last_beat=$now
  fi
  sleep 10
done
wait "$pid"; rc=$?
say "drain-hook.sh exited $rc (0 drained/idle/stopped, 2 timeout, 3 forced, 4 failed, 5 busy)"
if aws autoscaling complete-lifecycle-action --region "$region" --auto-scaling-group-name "$asg" \
  --lifecycle-hook-name "$hook" --instance-id "$iid" --lifecycle-action-result CONTINUE >/dev/null; then
  say "lifecycle action completed (CONTINUE)"
else
  say "complete-lifecycle-action failed (the hook times out to CONTINUE)"
fi
# Stay up (systemd would restart us into the loop again); the instance is going away.
sleep infinity
