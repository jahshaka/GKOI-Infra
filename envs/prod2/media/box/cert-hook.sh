#!/bin/bash
# cert-hook.sh — certbot's deploy hook on a GKOI media box (installed by media-bootstrap.sh phase certs), and the
# hourly retry of a deferred pool restart (gkoi-media-cert-retry.timer → cert-hook.sh --pending).
#   the ORIGIN lineage (config .origin_host)  → nginx -s reload in media-origin (re-reads the cert; drops nothing)
#   the STREAM lineage (config .stream_host)  → MediaMTX reads its RTMPS cert only at start: restart the pools, but ONLY
#                                               while the box is idle (a restart cuts every publisher); otherwise leave
#                                               a marker for the hourly retry (the engine's edge-cert-renew-hook.sh rule)
#   any other lineage (the names not served yet) → nothing
# The same race as the engine's hook is accepted: a session starting between the idle check and the restart is cut.
set -euo pipefail
GKOI_MEDIA_WHO=cert-hook
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=media-lib.sh
. "$HERE/media-lib.sh"
MARKER="$STATE/pool-cert.pending"

restart_pools() {
  local s pools=()
  for s in $(compose config --services); do case "$s" in mk-pool-*) pools+=("$s") ;; esac; done
  [ ${#pools[@]} -gt 0 ] || return 0
  if box_idle; then
    compose restart "${pools[@]}" >/dev/null && rm -f "$MARKER" && say "pools restarted on the renewed RTMPS cert"
  else
    install -d -m 0755 "$STATE"; touch "$MARKER"
    say "the box is busy — pool restart deferred (hourly retry): $(box_report)"
  fi
}

if [ "${1:-}" = --pending ] || [ "${1:-}" = --retry ]; then
  [ -f "$MARKER" ] || exit 0
  restart_pools
  exit 0
fi

host="$(basename "${RENEWED_LINEAGE:-}")"
[ -n "$host" ] || die "RENEWED_LINEAGE is not set (certbot sets it for a deploy hook)"
[ -f "$COMPOSE_FILE" ] || { say "no compose file yet — nothing to reload for $host"; exit 0; }
if [ "$host" = "$(cfg .origin_host)" ]; then
  c="$(container_of media-origin)"
  if [ -n "$c" ]; then docker exec "$c" nginx -s reload && say "media-origin reloaded for $host"; fi
fi
if [ "$host" = "$(cfg .stream_host)" ]; then
  restart_pools
fi
exit 0
