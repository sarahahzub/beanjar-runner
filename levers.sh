# Sourced by run.sh (MODE=levers). Memory and speed levers for WebOS Chromium: for each config, a fresh browser start,
# the same three pages as tabs (Wikipedia, YouTube watch, BBC News), 60 s to settle, then the browser's total PSS, its
# process count and MemAvailable, and each page's load time. The installed run.sh gets hooks ($T/lever.sh sets CN_DIS,
# CN_EN, CN_JS, CN_EXTRA and env vars); media.opts js=full keeps V8 the same in every config. Baseline runs first and
# last (noise). Results: lev_<config>=... in results.txt.
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/levers; mkdir -p "$B"
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
fwd() { pkill -f 'ssh .*-L 9222' 2>/dev/null; sleep 1
	(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } > "$B/fwd.log" 2>&1 &); sleep 4; }
stop_app() {
	gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
	local t2=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t2 )) -lt 30 ]; do sleep 3; done
	local p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null; sleep 5; }
memsum() { gsh "n=0; pss=0; rss=0; for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' || continue; n=\$((n+1)); f=\$p/smaps_rollup; [ -r \$f ] || f=\$p/smaps; set -- \$(awk '/^Pss:/{p+=\$2} /^Rss:/{r+=\$2} END{print p+0, r+0}' \$f 2>/dev/null); pss=\$((pss+\${1:-0})); rss=\$((rss+\${2:-0})); done; echo procs=\$n pss_mb=\$((pss/1024)) rss_mb=\$((rss/1024)) avail_mb=\$(awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo)" | tail -1; }

step levers-prep
(timeout 7200 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
timeout 90 beanjar screensaver stop tv1 >/dev/null 2>&1
( while sleep 45; do timeout 40 beanjar screensaver stop tv1 >/dev/null 2>&1; done ) & SSLOOP=$!
res guest_release "$(gsh 'head -1 /etc/starfish-release' | tail -1)"
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1; res install "rc=$? $(tail -1 "$B/ares-install.txt" | cut -c1-80)"
APPDIR=/media/developer/apps/usr/palm/applications/$ID
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"
RSH=$APPDIR/bin/run.sh   # not R: run.sh keeps results.txt in $R
gsh_in "cat > /tmp/levers.sed" < /w/levers.sed
gsh "sed -i -f /tmp/levers.sed $RSH; grep -n -E 'lever.sh|CN_EN|CN_DIS|CN_JS|CN_EXTRA' $RSH | cut -c1-120; sh -n $RSH && echo syntax-ok" > "$B/runsh-hooks.txt"
res hooks "$(grep -c CN_ "$B/runsh-hooks.txt") $(tail -1 "$B/runsh-hooks.txt")"
gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" >/dev/null; sleep 50   # warm-up: the app makes $T as its own user

config() { # $1 name, $2 lever.sh content
	step levers-$1
	stop_app
	printf '%s\n' "$2" | gsh_in "cat > $T/lever.sh"
	gsh "echo --remote-debugging-port=9222 > $T/browser.flags; echo js=full > $T/media.opts; chmod 644 $T/lever.sh $T/browser.flags $T/media.opts; chown \$(stat -c %u $T) $T/lever.sh $T/browser.flags $T/media.opts 2>/dev/null; true"
	local t=$(date +%s)
	gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" >/dev/null
	sleep 15; fwd
	local n=0; while [ $n -lt 40 ] && ! curl -s -m 3 http://127.0.0.1:9222/json/version >/dev/null; do sleep 3; n=$((n+1)); [ $((n % 10)) = 0 ] && fwd; done
	local up=$(( $(date +%s) - t ))
	local idle=$(memsum)
	local loads=$(timeout 240 python3 /w/levers.py 2>&1 | tail -1 | cut -c1-200)
	sleep 60
	local m=$(memsum)
	local tabs=$(curl -s -m 10 http://127.0.0.1:9222/json/list | grep -c '"type": "page"')
	gsh "c=\$(for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q -- '${ID}/browser/chrome.*--user-data-dir' && ! tr '\\0' ' ' < \$p/cmdline | grep -q -- '--type=' && echo \${p#/proc/}; done | head -1); tr '\\0' ' ' < /proc/\$c/cmdline | grep -o -E 'skia-[a-z-]*=[0-9]+|max-semi-space-size=[0-9]+|Prerender2|PartitionAllocMemoryReclaimer' | sort -u | tr '\\n' ' '; tr '\\0' '\\n' < /proc/\$c/environ | grep MALLOC" > "$B/$1-applied.txt"
	res lev_$1 "start_s=$up idle[$idle] 3tabs+60s[$m] pages=$tabs loads=$loads applied=[$(tr '\n' ' ' < "$B/$1-applied.txt" | cut -c1-200)]"
	pkill -f 'ssh .*-L 9222' 2>/dev/null
}
for rep in 1 2; do
	config base$rep ''
	config prefetch$rep 'CN_DIS=",Prerender2,SearchPrefetchServicePrefetching,PreconnectToSearch,LoadingPredictorPrefetch,NoStatePrefetch"'
	config arena$rep 'export MALLOC_ARENA_MAX=2'
	config v8young$rep 'CN_JS=" --max-semi-space-size=1 --memory-reducer-for-small-heaps"'
	config skia$rep 'CN_EXTRA="--skia-resource-cache-limit-mb=16 --skia-font-cache-limit-mb=2"'
	config pa$rep 'CN_EN=",PartitionAllocMemoryReclaimer,PartitionAllocLargeEmptySlotSpanRing,PartitionAllocSortActiveSlotSpans,PartitionAllocStraightenLargerSlotSpanFreeLists,MemoryPurgeInBackground"'
	config all$rep 'export MALLOC_ARENA_MAX=2; CN_DIS=",Prerender2,SearchPrefetchServicePrefetching,PreconnectToSearch,LoadingPredictorPrefetch,NoStatePrefetch"; CN_JS=" --max-semi-space-size=1 --memory-reducer-for-small-heaps"; CN_EXTRA="--skia-resource-cache-limit-mb=16 --skia-font-cache-limit-mb=2"; CN_EN=",PartitionAllocMemoryReclaimer,PartitionAllocLargeEmptySlotSpanRing,PartitionAllocSortActiveSlotSpans,PartitionAllocStraightenLargerSlotSpanFreeLists,MemoryPurgeInBackground"'
done
stop_app
kill $SSLOOP 2>/dev/null
gsh "rm -f $T/lever.sh $T/media.opts $T/browser.flags"
res levers_result done
