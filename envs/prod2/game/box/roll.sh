#!/bin/bash
# roll.sh — roll a GKOI prod2 game box to what its SSM config now names, IN PLACE, over SSM (no new instance).
#
#   roll.sh [--dry-run]
#
# A War Room release = tools/gkoi-release warroom-game <tag> → commit envs/prod2/releases/warroom-game.json → apply the
# game stack (it rewrites /gkoi/prod2/game/<key>/config: the image digest + tag, the tool zip) → run this on the box:
#
#   aws ssm send-command --region <r> --document-name AWS-RunShellScript \
#     --targets Key=tag:aws:autoscaling:groupName,Values=gkoi-prod2-game-<key> \
#     --parameters 'commands=["/opt/gkoi-game/roll.sh"]' --timeout-seconds 9000
#
# The same for a NAME switch (serve_live_names flipped) and a rotated secret. It is game-bootstrap.sh apply (every
# phase is idempotent): the new config + bundle + tool; the env file + matchd.json re-rendered — a change on a running
# stack DRAINS it first (`warroom-game.sh drain`: new matches refused, live ones finish, up to WARROOM_DRAIN_TIMEOUT
# = 7500 s); a new cert lineage when the names changed (the stale one deleted); the image pulled; then the tool's own
# `deploy <tag>` (drain → the version fields → up → /v1/version + the gateway checked) or `up`. A failed roll leaves the
# stack as the tool left it: `warroom-game.sh status`, and `rollback` (the previous tag's image stays on the box).
# --dry-run: the config + tool refresh only, then what the render would change and which tag would be deployed.
set -euo pipefail
export HOME="${HOME:-/root}"; cd /
GKOI_GAME_WHO=roll
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=game-lib.sh
. "$HERE/game-lib.sh"

dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    *) echo "usage: roll.sh [--dry-run]" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || die "run as root (SSM runs as root)"

say "== roll $(date -u +%FT%TZ): refreshing the config, the bundle and the tool"
"$BOX/game-bootstrap.sh" apply --only config,tool
if [ $dry -eq 1 ]; then
  GKOI_GAME_DRY=1 "$BOX/game-bootstrap.sh" apply --only render
  say "dry run: running '$(running_tag)', the config names $(cfg .image.tag) (${CFG}), serving $(cfg .matchd_host) + $(cfg .gateway_host)"
  exit 0
fi
"$BOX/game-bootstrap.sh" apply
"$BOX/game-bootstrap.sh" check || die "rolled, but the check is not clean (above)"
say "== rolled: $(cfg .image.tag) serving $(cfg .matchd_host) + $(cfg .gateway_host)"
