# Sourced by run.sh (MODE=launch) once the TV has booted (helpers res, step, el, gsh, gshl, shot, fg, press, SSH_ROOT
# come from run.sh). Does the browser IPK (/w/brave.ipk, hash checked by the workflow) start at all? Installs it,
# launches it three times, and for each start records the foreground app, the browser's processes, free memory, the
# app's own logs (/tmp/<id>: media.log, start-check.log, browser.log) and what SAM and the memory manager logged.
# Written for issue #29 (49SK8000PVA, webOS 4.4.3: the app doesn't open, or the TV switches to HDMI 2).
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/launch; mkdir -p "$B"
res app_id "$ID"
gsh true >/dev/null
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
launcher() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/bin/run' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
mem() { gsh "grep -E 'MemTotal|MemAvailable|SwapFree' /proc/meminfo | tr -s ' ' | tr '\\n' ' '" | tail -1; }
ML=0
mark() { ML=$(gsh "wc -l < /var/log/messages" | tail -1 | tr -dc 0-9); }
applogs() { # $1 tag
	gsh "cd $T 2>/dev/null && for f in start-check.log media.log media.opts browser.flags lite.txt guard.log; do [ -f \$f ] && { echo \"==== \$f\"; cat \$f; }; done; [ -f $T/browser.log ] && { echo '==== browser.log (last 120, no GPU buffer lines)'; grep -a -v -E 'create_wl_buffer|dbus' $T/browser.log | tail -n 120; }" > "$B/app-$1.txt"
	gsh "tail -n +$((ML + 1)) /var/log/messages 2>/dev/null | grep -a -i -E '$ID|sam|memchute|NL_MM|appinstall|lsm|crash|segfault|killed|oom|launch|requiredMemory|not enough' | tail -n 80" > "$B/messages-$1.txt"
	gsh "dmesg 2>/dev/null | tail -n 40" > "$B/dmesg-$1.txt"
	gsh "ls -l /tmp/faultmanager /var/log/reports/librdx 2>/dev/null | tail -n 20" > "$B/crashes-$1.txt"
}

step launch-prep
(timeout 5400 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
( while sleep 45; do timeout 40 beanjar screensaver stop tv1 >/dev/null 2>&1; done ) &
SSLOOP=$!
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1; res screensaver_stop_rc $?
press HOME; sleep 8; shot launch-home >/dev/null
gsh "cat /etc/starfish-release; uname -m; /lib/libc.so.6 2>&1 | head -1; grep -E 'MemTotal|MemAvailable|SwapTotal' /proc/meminfo; df -h /media/developer /tmp 2>/dev/null" > "$B/guest.txt"
res guest_release "$(head -1 "$B/guest.txt")"
res guest_glibc "$(grep -o -m1 'version [0-9.]*' "$B/guest.txt")"
gsh "luna-send -n 1 luna://com.webos.service.tv.systemproperty/getSystemInfo '{\"keys\":[\"modelName\",\"firmwareVersion\",\"sdkVersion\",\"boardType\"]}'" > "$B/sysinfo.json"
res sysinfo "$(tr -d '\n' < "$B/sysinfo.json" | cut -c1-300)"

step launch-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
t=$(date +%s); timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1
res install "rc=$? s=$(( $(date +%s) - t )) $(tail -1 "$B/ares-install.txt" | cut -c1-150)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res launch_result "install failed"; kill $SSLOOP 2>/dev/null; return 0; }
gsh "cat $APPDIR/appinfo.json; echo; cat $APPDIR/bin/requires; ls -l $APPDIR $APPDIR/bin; du -sh $APPDIR" > "$B/appdir.txt"
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"
# (no root test run of bin/run here: as root it makes /tmp/<id> root's, and the app's own user then can't start)

for n in 1 2 3; do
	step launch-try$n
	mark
	res try${n}_mem_before "$(mem)"
	t=$(date +%s)
	gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" > "$B/launch$n.txt"
	res try${n}_call "$(tr -d '\n' < "$B/launch$n.txt" | cut -c1-200)"
	first=""; seen_l=""; i=0
	while [ $(( $(date +%s) - t )) -lt 120 ]; do
		sleep 5; i=$((i + 1))
		l=$(launcher); p=$(procs); f=$(fg | tail -1)
		[ -n "$l" ] && seen_l="${seen_l:-$(( $(date +%s) - t ))s}"
		[ -n "$p" ] && [ -z "$first" ] && first="$(( $(date +%s) - t ))s"
		echo "t=$(( $(date +%s) - t )) fg=$f launcher=[$l] chrome=[$p] $(mem)" >> "$B/try$n-timeline.txt"
		[ "$f" = "$ID" ] && [ -n "$p" ] && [ $(( $(date +%s) - t )) -ge 40 ] && break
	done
	res try${n}_launcher_seen "${seen_l:-never}"
	res try${n}_chrome_first "${first:-never}"
	res try${n}_end "$(tail -1 "$B/try$n-timeline.txt")"
	shot launch-try$n >/dev/null
	applogs try$n
	res try${n}_startcheck "$(grep -A3 '==== start-check.log' "$B/app-try$n.txt" | tail -n +2 | tr '\n' ' ' | cut -c1-200)"
	res try${n}_media_log "$(grep -A40 '==== media.log' "$B/app-try$n.txt" | grep -v '====' | tail -n 6 | tr '\n' ' ' | cut -c1-400)"
	res try${n}_messages "$(tail -n 6 "$B/messages-try$n.txt" | tr '\n' ' ' | cut -c1-500)"
	gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
	t2=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t2 )) -lt 30 ]; do sleep 3; done
	p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null
	sleep 10
done
kill $SSLOOP 2>/dev/null
res launch_result "try1=$(grep -m1 try1_chrome_first "$R" | cut -d= -f2) try2=$(grep -m1 try2_chrome_first "$R" | cut -d= -f2) try3=$(grep -m1 try3_chrome_first "$R" | cut -d= -f2)"

# Video check (launcher 1.1.1+): does LG's player library have the C++11 Feed the launcher hooks, and which player
# does the launcher load for an H.264 clip (BUFFERSTREAM or NDL's own)? Beanjar has no real decoder, so this checks
# the setup messages, not the picture.
step launch-video
gsh "ls -l /usr/lib/libAcbAPI.so* 2>&1; for f in /usr/lib/libplayerAPIs.so.1 /usr/lib/libNDL_directmedia_impl.so.1 /usr/lib/libNDL_directmedia.so.1; do [ -e \$f ] || { echo \"\$f missing\"; continue; }; echo \"\$f: feed_cxx11=\$(grep -a -c '_ZN17StarfishMediaAPIs4FeedB5cxx11EPKc' \$f) feed_old=\$(grep -a -c '_ZN17StarfishMediaAPIs4FeedEPKc' \$f) load=\$(grep -a -c '_ZN17StarfishMediaAPIs4LoadEPKcPFvixS1_E' \$f) ndlload=\$(grep -a -c 'NDL_DirectMediaLoad' \$f)\"; done" > "$B/symbols.txt"
res symbols "$(tr '\n' ' ' < "$B/symbols.txt" | cut -c1-500)"
gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null; sleep 8
gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\",\"params\":{\"target\":\"https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4\"}}'" > "$B/launch-video.txt"
sleep 60
gsh "grep -E 'ndl api|smp|direct player|acb event|open codec|video frame|play =|nohw|unload|init =|load failed|dlopen|missing' $T/media.log | cut -c1-400 | head -n 60" > "$B/video-media.txt"
gsh "grep -a -E 'cn-ndl: (hardware|audio)|software' $T/browser.log | tail -n 4" > "$B/video-browser.txt"
shot launch-video >/dev/null
res video_player "$(grep -o -E 'direct player: (on|off)[^,]*|direct player: load = [01]|smp load( \(BUFFERSTREAM\)| \(NDL.s game player\))?|libplayerAPIs has no C\+\+11 Feed[^|]*|ndl api: [a-z]*' "$B/video-media.txt" | sort | uniq -c | tr '\n' ' ')"
res video_load "$(grep -E 'smp load =|open codec|init =' "$B/video-media.txt" | tr '\n' ' ' | cut -c1-300)"
res video_feeds "$(grep -E 'smp feed|direct player: (feed|first frame|load completed|display window|event)|acb event' "$B/video-media.txt" | head -n 12 | tr "\n" " " | cut -c1-1500)"
