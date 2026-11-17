#!/usr/bin/env bash
# Offline test of tools/gkoi-origin-header against fake-aws (a few lines of secretsmanager / cloudfront / elbv2 with
# its state in a temp file): the first roll-out, every guard, a whole rotation, an abort, and the trailing-newline
# case. No AWS call. Run: tools/tests/origin-header/run.sh   (exit 0 = all steps as expected)
set -u
D="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; T="$D/../../gkoi-origin-header"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export GKOI_AWS="$D/fake-aws" FAKE_STATE="$W/state.json"
python3 -I - "$FAKE_STATE" <<'PY'
import json, sys
def dist(dom, extra=None):
    o = [{"Id": dom, "DomainName": dom, "CustomHeaders": {"Quantity": 0}}]
    if extra: o.append({"Id": extra, "DomainName": extra, "CustomHeaders": {"Quantity": 0}})
    return {"status": "Deployed", "config": {"Origins": {"Quantity": len(o), "Items": o}, "Comment": "x"}}
json.dump({"versions": {}, "lock_values": 0, "dists": {
    "E32GUUVFJFZWS7": dist("origin-www.gkoi.com"), "E16YQ7HYLBQUPQ": dist("origin-cdn.gkoi.com", "files.gkoi.com"),
    "E28154TBILFIGK": dist("origin-labs.gkoi.com")}}, open(sys.argv[1], "w"))
PY
setlock() { python3 -I -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['lock_values']=int(sys.argv[2]); json.dump(d,open(p,'w'))" "$FAKE_STATE" "$1"; }
# state facts: "<number of versions> <stages of each, sorted> | <distinct header fingerprints on the 3 locked origins> | files-origin-headers"
facts() { python3 -I - "$FAKE_STATE" <<'PY'
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
fp = lambda v: hashlib.sha256(v.encode()).hexdigest()[:8]
by = {s: fp(v["value"]) for v in d["versions"].values() for s in v["stages"]}
cf = set(); other = 0
for dist in d["dists"].values():
    for o in dist["config"]["Origins"]["Items"]:
        hs = [fp(h["HeaderValue"]) for h in o["CustomHeaders"].get("Items", [])]
        if o["DomainName"].startswith("origin-"): cf.add(hs[0] if hs else "-")
        else: other += len(hs)
name = lambda f: next((s for s, v in by.items() if v == f), f)
print("stages=" + ",".join(sorted(by)), "cf=" + ",".join(sorted(name(f) for f in cf)), "other=%d" % other)
PY
}
fails=0; n=0
step() { # <expected rc> <expected text> <expected facts after | -> <args…>
  local rc want="$1" text="$2" fx="$3" out got; shift 3; n=$((n + 1))
  out="$("$T" "$@" 2>&1)"; rc=$?; got="$(facts)"
  if [ "$rc" != "$want" ] || ! grep -qF -- "$text" <<<"$out" || { [ "$fx" != - ] && [ "$got" != "$fx" ]; }; then
    fails=$((fails + 1)); echo "FAIL $n: $* → rc $rc (want $want), want text '$text', facts '$got' (want '$fx')"; sed 's/^/     /' <<<"$out"
  else echo "ok   $n: $* → rc $rc; $got"; fi
}
step 1 "NOT READY"             -                                               check          # nothing yet
step 0 "read back identical"   "stages=AWSCURRENT cf=AWSCURRENT other=0"       set
step 0 "READY"                 -                                               check
step 1 "already sends"         "stages=AWSCURRENT cf=AWSCURRENT other=0"       set
setlock 1
step 1 "REFUSED"               "stages=AWSCURRENT cf=AWSCURRENT other=0"       remove
step 1 "ROTATION"              -                                               set
step 1 "no AWSPENDING"         -                                               push
step 0 "stored as AWSPENDING"  "stages=AWSCURRENT,AWSPENDING cf=AWSCURRENT other=0" stage
step 1 "second one is refused" "stages=AWSCURRENT,AWSPENDING cf=AWSCURRENT other=0" stage
step 1 "accepts only 1"        "stages=AWSCURRENT,AWSPENDING cf=AWSCURRENT other=0" push
step 0 "all three send AWSCURRENT" -                                           check
setlock 2
step 1 "'push' first"          "stages=AWSCURRENT,AWSPENDING cf=AWSCURRENT other=0" promote
step 0 "all three Deployed"    "stages=AWSCURRENT,AWSPENDING cf=AWSPENDING other=0" push
step 1 "do not abort"          "stages=AWSCURRENT,AWSPENDING cf=AWSPENDING other=0" abort
step 0 "next: 'promote'"       -                                               check
step 0 "is AWSCURRENT"         "stages=AWSCURRENT,AWSPREVIOUS cf=AWSCURRENT other=0" promote
step 0 "READY"                 -                                               check
setlock 1
step 0 "stored as AWSPENDING"  "stages=AWSCURRENT,AWSPENDING,AWSPREVIOUS cf=AWSCURRENT other=0" stage
step 0 "dropped"               "stages=AWSCURRENT,AWSPREVIOUS cf=AWSCURRENT other=0" abort
step 0 "WILL be refused"       "stages=AWSCURRENT,AWSPREVIOUS cf=- other=0"    remove --force-while-locked-THE-SITE-WILL-403
step 1 "sends NO header"       -                                               check
step 0 "updated"               "stages=AWSCURRENT,AWSPREVIOUS cf=AWSCURRENT other=0" repair
# B1: a store that hands back the value with a trailing newline is caught before anything reaches CloudFront
export FAKE_ADD_NEWLINE=1
step 1 "WHITESPACE"            "stages=AWSCURRENT,AWSPENDING,AWSPREVIOUS cf=AWSCURRENT other=0" stage
unset FAKE_ADD_NEWLINE
setlock 2
step 1 "malformed"             -                                               push
step 0 "dropped"               "stages=AWSCURRENT,AWSPREVIOUS cf=AWSCURRENT other=0" abort
echo "$((n - fails))/$n steps as expected"; [ "$fails" = 0 ]
