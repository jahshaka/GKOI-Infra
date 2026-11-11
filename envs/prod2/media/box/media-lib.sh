#!/bin/bash
# media-lib.sh — shared by media-bootstrap.sh, roll.sh, cert-hook.sh and lifecycle-watch.sh on a GKOI media box.
# Sourced, never run. Reads the box config (/etc/gkoi-media/config.json, written from the SSM parameter) and talks
# to IMDSv2, the media agent (its loopback /drain + /healthz, through `docker exec`) and the compose project.
# shellcheck shell=bash

# shellcheck disable=SC2034  # the constants are used by the scripts that source this file
TOOL=/opt/gkoi-media
ETC=/etc/gkoi-media
RUN="$TOOL/run"
CFG="$ETC/config.json"
STATE=/var/lib/gkoi-media
PROJECT=gkoi-media
COMPOSE_FILE="$RUN/compose.yml"
PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

WARNINGS=0
say()  { printf '%s: %s\n' "${GKOI_MEDIA_WHO:-gkoi-media}" "$*"; }
warn() { printf '%s: WARNING: %s\n' "${GKOI_MEDIA_WHO:-gkoi-media}" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '%s: FAILED: %s\n' "${GKOI_MEDIA_WHO:-gkoi-media}" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- the config ----------------------------------------------------------------------------------------------
cfg() { jq -er "$1" "$CFG"; }            # a required value (fails on null / missing)
cfg_or() { jq -r "($1) // \"$2\"" "$CFG"; } # with a default

# ---- IMDSv2 ----------------------------------------------------------------------------------------------------
IMDS=http://169.254.169.254/latest
imds_token() { curl -fsS --max-time 2 -X PUT "$IMDS/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 120' 2>/dev/null; }
imds() { local t; t="$(imds_token)" || return 1; curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $t" "$IMDS/$1" 2>/dev/null; }
instance_id() { imds meta-data/instance-id; }
private_ip() { imds meta-data/local-ipv4; }
public_ip() { imds meta-data/public-ipv4 || true; }
own_region() { imds meta-data/placement/region; }

# The box id in the engine's pool registry (MEDIA_BOX_ID, ≤ 48 of [A-Za-z0-9._-]): <slug>-<instance id without "i-">.
# One per INSTANCE on purpose: a replacement box never inherits a departed box's pool ids (the engine re-claims or ends
# that box's sessions — SPEC-PLATFORM-AWS-READY-V1 A2/A4), and the relay queue relay-box-<id> is the box's own.
box_id() { local iid; iid="$(instance_id)" || return 1; printf '%s-%s' "$(cfg .key)" "${iid#i-}"; }

# ---- the compose project ----------------------------------------------------------------------------------------
compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }
container_of() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" | head -1; }

# The agent's loopback endpoint (media-agent/src/health.ts): GET|POST|DELETE /drain → {box,draining,idle,sessions,recordings,builds}
agent_call() { # METHOD PATH → body on stdout; non-zero when the agent is not running or answers non-2xx
  local c; c="$(container_of media-agent)"; [ -n "$c" ] || return 1
  docker exec "$c" node -e "fetch('http://127.0.0.1:3002'+process.argv[2],{method:process.argv[1]}).then(async r=>{process.stdout.write(await r.text());process.exit(r.ok?0:1)}).catch(()=>process.exit(1))" "$1" "$2"
}

# 0 = the box holds nothing (no agent running, or the agent reports idle); 1 = busy (sessions / recordings / builds).
box_idle() {
  local c body; c="$(container_of media-agent)"
  [ -n "$c" ] || return 0
  body="$(agent_call GET /drain)" || { warn "the media agent does not answer /drain: treating the box as BUSY"; return 1; }
  [ "$(printf '%s' "$body" | jq -r '.idle')" = true ]
}

box_report() { agent_call GET /drain 2>/dev/null || printf '{"agent":"not running"}'; }
