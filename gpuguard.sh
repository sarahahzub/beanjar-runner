# Sourced by run.sh (MODE=gpuguard). Checks PR #40 (ViieeS: gpu.state counts only crash signals, two in a row turn
# the GPU off, a clean run clears the count, early-exit.log, media.opts words matched whole) on the real firmware.
# Steps: normal start and close; SIGSEGV within 60 s (twice); the next start; record cleared by a clean run;
# media.opts "webgpu=on" alone. After each: the launcher's gpu lines, gpu.state, early-exit.log.
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/gpuguard; mkdir -p "$B"
APPDIR=/media/developer/apps/usr/palm/applications/$ID
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
stop_app() {
	gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
	local t2=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t2 )) -lt 30 ]; do sleep 3; done
	local p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null; sleep 5; }
start() { gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" >/dev/null; sleep 25; }
statefile() { gsh "for f in $APPDIR/data/gpu.state $T/gpu.state; do [ -f \$f ] && { echo \"\$f: \$(tail -1 \$f)\"; }; done; true" | tr '\n' ' '; }
eelog() { gsh "for f in $APPDIR/data/early-exit.log $T/early-exit.log; do [ -f \$f ] && { echo \"\$f: \$(head -1 \$f) (\$(wc -l < \$f) lines)\"; }; done; true" | tr '\n' ' '; }
gpulines() { gsh "grep -a -E 'gpu:|chrome exited|toast sent' $T/media.log | sed 's/^[0-9.]* //' | cut -c1-170" | tr '\n' '|'; }
segv() { local p=$(gsh "sed -n 's/.*chrome wrapper pid \\([0-9]*\\).*/\\1/p' $T/media.log | tail -1" | tail -1); res "$1_pid" "$p"; gsh "kill -SEGV $p"; sleep 12; }
record() { res "gg_$1" "state=[$(statefile)] early=[$(eelog)] media=[$(gpulines)]"; gsh "cp $T/media.log /tmp/gg-media-$1.log 2>/dev/null"; gsh "cat $T/media.log" > "$B/media-$1.txt"; }

step gg-prep
(timeout 5400 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
( while sleep 45; do timeout 40 beanjar screensaver stop tv1 >/dev/null 2>&1; done ) & SSLOOP=$!
res guest_release "$(gsh 'head -1 /etc/starfish-release' | tail -1)"
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1; res install "rc=$? $(tail -1 "$B/ares-install.txt" | cut -c1-80)"
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"
res launcher "$(gsh "strings $APPDIR/bin/run | grep -c 'crashed twice'" | tail -1) (1+ = PR 40 launcher)"
start; stop_app   # warm-up: the app makes $T as its own user
gsh "rm -f $APPDIR/data/gpu.state $T/gpu.state $APPDIR/data/early-exit.log $T/early-exit.log; : > $T/media.opts"

step gg-1-clean;   start; stop_app;                 record 1_clean
step gg-2-segv1;   start; segv s1;                  record 2_segv1
step gg-3-after1;  start;                           record 3_after1_running
step gg-4-segv2;   segv s2;                         record 4_segv2
step gg-5-after2;  start; stop_app;                 record 5_after2
step gg-6-clear;   gsh "rm -f $APPDIR/data/gpu.state $T/gpu.state"; start; segv s3; start; stop_app; record 6_crash_then_clean
step gg-7-webgpu;  gsh "rm -f $APPDIR/data/gpu.state $T/gpu.state; echo webgpu=on > $T/media.opts; chmod 644 $T/media.opts"; start; stop_app; record 7_webgpu
step gg-8-gpuon;   gsh "echo gpu=on > $T/media.opts"; start; stop_app; record 8_gpuon_word
gsh "rm -f $T/media.opts $APPDIR/data/gpu.state $T/gpu.state"
kill $SSLOOP 2>/dev/null
res gg_result done
