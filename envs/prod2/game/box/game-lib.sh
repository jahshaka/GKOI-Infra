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

# ---- tools without the snap store (2026-11-11: api.snapcraft.io unreachable from a new ap-northeast-1 box for 15+ min;
# flaky for two game boxes the same day). Snap first with three short tries, then a fallback that needs no snap.
# Pinned AWS CLI v2 zip: version + sha256 (the sha256 of the file whose PGP signature was verified against the AWS CLI
# Team key FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C on 2026-11-11). Bump both together.
AWSCLI_VERSION=2.39.7
AWSCLI_SHA256=707a900fde102f486d92e79f979493c747f475b9e2b94f2a42687d5d95129fb7

SNAP_STORE_DOWN=0
snap_try() { # snap ARGS… → 0 when one of three short attempts succeeds (each capped at 90 s). After three failures the
  # store counts as down for the rest of this run: later snap_try calls fail at once (no 5 minutes per tool).
  have snap || return 1
  [ "$SNAP_STORE_DOWN" -eq 0 ] || return 1
  local i
  for i in 1 2 3; do
    timeout 90 snap "$@" && return 0
    warn "snap $* failed (attempt $i/3)"
    [ "$i" -lt 3 ] && sleep $((i * 5))
  done
  SNAP_STORE_DOWN=1
  return 1
}

ensure_aws_cli() { # an `aws` that runs: as it is, else the snap, else the pinned zip into /usr/local (needs curl + unzip)
  if have aws && aws --version >/dev/null 2>&1; then return 0; fi
  if snap_try install aws-cli --classic; then hash -r; if have aws && aws --version >/dev/null 2>&1; then return 0; fi; fi
  say "aws cli: no snap — installing $AWSCLI_VERSION from awscli.amazonaws.com (sha256 pinned)"
  have unzip || die "aws cli fallback: unzip is not installed"
  local d; d="$(mktemp -d)"
  curl -fsSL --retry 3 --max-time 600 -o "$d/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWSCLI_VERSION.zip" \
    || { rm -rf "$d"; die "cannot download the AWS CLI $AWSCLI_VERSION"; }
  echo "$AWSCLI_SHA256  $d/awscli.zip" | sha256sum -c --quiet - || { rm -rf "$d"; die "the AWS CLI zip does not match its pinned sha256"; }
  unzip -q "$d/awscli.zip" -d "$d" || { rm -rf "$d"; die "cannot unzip the AWS CLI"; }
  "$d/aws/install" --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin --update >/dev/null || { rm -rf "$d"; die "the AWS CLI installer failed"; }
  rm -rf "$d"; hash -r
  aws --version >/dev/null 2>&1 || die "the AWS CLI does not run after its install"
  say "aws cli: $(aws --version 2>&1)"
}

ssm_agent_active() { # the SSM agent of Canonical's AMI (snap) or a deb/rpm install
  systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null \
    || systemctl is-active --quiet amazon-ssm-agent.service 2>/dev/null
}

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
