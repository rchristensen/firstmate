#!/usr/bin/env bash
# Live driver for issue #7320: fm_backend_herdr_server_ensure against a real
# Herdr lab session (fm-lab-*), provisioned/stopped/torn down via bin/fm-herdr-lab.sh.
set -u
WT=$1
cd "$WT"
LAB="$WT/bin/fm-herdr-lab.sh"
S=$("$LAB" name ensure7320)
log() { printf '[%s] %s\n' "$(date +%T.%N | cut -c1-12)" "$*"; }
ensure() { bash -c '. bin/backends/herdr.sh && fm_backend_herdr_server_ensure "$1"' _ "$S"; }
running() { herdr status --json --session "$S" 2>/dev/null | jq -r '.server.running // false'; }
nservers() { pgrep -fc -- "server --session $S\$" || true; }
trap '"$LAB" teardown "$S"; log "teardown rc=$?"' EXIT
log "lab session: $S"
"$LAB" provision "$S" || { log "provision failed"; exit 1; }
DIR=$(herdr session list --json --session "$S" | jq -r --arg n "$S" '.sessions[]|select(.name==$n)|.session_dir')
log "session_dir=$DIR running=$(running) servers=$(nservers)"
OWN="$DIR/firstmate-server-owner"; REP="$DIR/firstmate-server-replacing"

echo; log "=== S1 fast path: server running, no markers ==="
t0=$(date +%s.%N); ensure; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"

echo; log "=== S2 replacement marker while running: callers wait, then proceed ==="
touch "$REP"; t0=$(date +%s.%N)
ensure & p=$!
sleep 4; if kill -0 $p 2>/dev/null; then log "after 4s: ensure STILL WAITING (running=$(running), marker present)"; else log "after 4s: ensure already returned (BAD)"; fi
rm -f "$REP"; log "marker removed"
wait $p; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"

echo; log "=== S3 replacement marker never clears (server running): bounded wait, clear error ==="
touch "$REP"; t0=$(date +%s.%N)
ensure; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"
rm -f "$REP"

echo; log "=== S4 externally managed (owner marker), server down: never starts, bounded wait, error names owner ==="
"$LAB" stop "$S" >/dev/null; sleep 1
printf 'systemd user unit herdr@%s.service\n' "$S" > "$OWN"
log "stopped: running=$(running) servers=$(nservers); owner marker: $(cat "$OWN")"
t0=$(date +%s.%N); ensure; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"

echo; log "=== S5 owner-managed live handoff: replacement marker, owner restarts server, callers proceed only after marker clears ==="
touch "$REP"; t0=$(date +%s.%N)
ensure & p=$!
sleep 3; log "after 3s: waiting=$(kill -0 $p 2>/dev/null && echo yes || echo no) running=$(running) servers=$(nservers)"
log "owner (stand-in: lab provision) brings the server back"; "$LAB" provision "$S"
log "server back: running=$(running) servers=$(nservers)"
sleep 3; log "3s later, marker still present: waiting=$(kill -0 $p 2>/dev/null && echo yes || echo no)"
rm -f "$REP"; log "replacement marker removed"
wait $p; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"

echo; log "=== S6 Firstmate-owned default (no markers), server down: ensure starts it ==="
rm -f "$OWN" "$REP"; "$LAB" stop "$S" >/dev/null; sleep 1
log "stopped: running=$(running) servers=$(nservers)"
t0=$(date +%s.%N); ensure; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"

echo; log "=== S7 replacement marker with no owner, server down: wait, then Firstmate start once marker clears ==="
"$LAB" stop "$S" >/dev/null; sleep 1; touch "$REP"
log "stopped: running=$(running) servers=$(nservers)"
t0=$(date +%s.%N); ensure & p=$!
sleep 3; log "after 3s: waiting=$(kill -0 $p 2>/dev/null && echo yes || echo no) running=$(running) servers=$(nservers)"
rm -f "$REP"; log "marker removed"
wait $p; rc=$?; t1=$(date +%s.%N)
log "rc=$rc elapsed=$(python3 -c "print(round($t1-$t0,2))")s running=$(running) servers=$(nservers)"
echo
