#!/bin/bash
# game-lib.sh — shared by game-bootstrap.sh, roll.sh and lifecycle-watch.sh on a GKOI game box. Sourced, never run.
# Reads the box config (/etc/gkoi-game/config.json, written from the SSM parameter /gkoi/prod2/game/<key>/config) and
# knows where the War Room tool (ops/warroom-game, unpacked into /opt/warroom-game) keeps its files.
# shellcheck shell=bash

# shellcheck disable=SC2034  # the constants are used by the scripts that source this file
BOX=/opt/gkoi-game                    # this bundle (envs/prod2/game/box)
ETC=/etc/gkoi-game
CFG="$ETC/config.json"
STATE=/var/lib/gkoi-game
WR=/opt/warroom-game                  # the War Room tool (the release's source.zip: ops/warroom-game)
BOX_ENV="$WR/ops.box.env"             # THIS box's env file: the tool's ops.<warroom_env>.env + the box's names
PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

WARNINGS=0
say()  { printf '%s: %s\n' "${GKOI_GAME_WHO:-gkoi-game}" "$*"; }
warn() { printf '%s: WARNING: %s\n' "${GKOI_GAME_WHO:-gkoi-game}" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '%s: FAILED: %s\n' "${GKOI_GAME_WHO:-gkoi-game}" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- the config ----------------------------------------------------------------------------------------------
cfg() { jq -er "$1" "$CFG"; }            # a required value (fails on null / missing)
cfg_or() { jq -r "($1) // \"$2\"" "$CFG"; } # with a default

# ---- IMDSv2 ----------------------------------------------------------------------------------------------------
IMDS=http://169.254.169.254/latest
imds_token() { curl -fsS --max-time 2 -X PUT "$IMDS/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 120' 2>/dev/null; }
imds() { local t; t="$(imds_token)" || return 1; curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $t" "$IMDS/$1" 2>/dev/null; }
instance_id() { imds meta-data/instance-id; }
public_ip() { imds meta-data/public-ipv4 || true; }
own_region() { imds meta-data/placement/region; }

# ---- the War Room tool, as the box user (its state + config dir are the box user's; the live boxes run it so) -----
env_get() { [ -r "$BOX_ENV" ] || return 0; sed -n "s/^$1=//p" "$BOX_ENV" | tail -1; }
wr() { local u; u="$(env_get WARROOM_BOX_USER)"; sudo -u "${u:-ubuntu}" -H "$WR/warroom-game.sh" --env "$BOX_ENV" "$@"; }
# The tag the container runs ("" = none): the image name of the running warroom-game-<env> container.
running_tag() {
  local env; env="$(env_get WARROOM_ENV)"; [ -n "$env" ] || return 0
  { docker ps --filter "name=^/warroom-game-$env\$" --format '{{.Image}}' 2>/dev/null || true; } | sed -n 's/^warroom-game://p' | head -1
}
