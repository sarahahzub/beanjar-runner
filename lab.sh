# Sourced by run.sh (MODE=lab) once the TV has booted (helpers res, step, gsh, gsh_in, shot, fg, SSH_ROOT from run.sh).
# Opens the test lab page (LAB_URL, served from Oracle through Tailscale Funnel) in the installed browser and runs:
#  1. fonts with the TV's own fontconfig: real font per script (CDP), tofu check, screenshot
#  2. fonts with PR #22's fonts.conf (ViieeS): same, plus the first start time (fontconfig builds its cache)
#  3. media tests: codecs, A/V sync clip, 1080p60, VP9+Opus, MSE, same-origin iframe, YouTube embed, two videos,
#     AAC and Opus audio, fullscreen (#39)
#  4. screen saver: a looping video for 6 min without key presses (should keep the screen saver away), then paused for
#     6 min (control: the screen saver should come). Records tvpower's state, the foreground app and the launcher's
#     "screensaver:" lines.
# No "beanjar screensaver stop" here: it would hide what the screen saver does.
LS=luna://com.webos.applicationManager
LAB_URL=${LAB_URL:-https://zora.tail662e72.ts.net/webapp/cnlab/}
PR22_CONF=${PR22_CONF:-https://raw.githubusercontent.com/ViieeS/WebOS-Chromium/fontconfig-tv-fonts/source/package/fonts.conf}
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/lab; mkdir -p "$B"
res app_id "$ID"
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
ML=0
mark() { ML=$(gsh "wc -l < /var/log/messages" | tail -1 | tr -dc 0-9); }
fwd() { pkill -f 'ssh .*-L 9222' 2>/dev/null; sleep 1
	(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } > "$B/fwd.log" 2>&1 &); sleep 4; }
cdp_up() { # waits up to $1 s for the debug port; prints seconds
	local t=$(date +%s); while [ $(( $(date +%s) - t )) -lt $1 ]; do
		curl -s -m 3 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && { echo $(( $(date +%s) - t )); return 0; }
		fwd >/dev/null 2>&1; sleep 2; done; echo never; return 1; }
stop_app() {
	gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
	local t2=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t2 )) -lt 30 ]; do sleep 3; done
	local p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null; sleep 4; }
start_lab() { # $1 tag; starts the browser on the lab page with the debug port, records time to page loaded
	stop_app
	gsh "printf '%s\n' --remote-debugging-port=9222 > $T/browser.flags; : > $T/media.opts; chmod 644 $T/browser.flags $T/media.opts; chown \$(stat -c %u $T) $T/browser.flags $T/media.opts 2>/dev/null; true"
	mark; local t=$(date +%s)
	gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\",\"params\":{\"target\":\"$LAB_URL\"}}'" > "$B/$1-launch.txt"
	sleep 10; fwd
	res lab_$1_cdp_s "$(( $(cdp_up 150 >/dev/null; date +%s) - t ))"
	local n=0; while [ $n -lt 40 ]; do
		[ "$(timeout 20 python3 /w/cdp.py eval "typeof LAB==='object' && LAB.tests.length" 2>/dev/null)" -gt 0 ] 2>/dev/null && break
		sleep 3; n=$((n + 1)); done
	res lab_$1_page_s "$(( $(date +%s) - t ))"
}
fonts_round() { # $1 tag
	timeout 60 python3 /w/lab.py fonts > "$B/$1-fonts-cdp.json" 2>&1
	timeout 90 python3 /w/lab.py run fonts 80 > "$B/$1-fonts-js.json" 2>&1
	timeout 30 python3 /w/lab.py show '#fonts' >/dev/null 2>&1; sleep 2; shot lab-$1-fonts >/dev/null
	res lab_$1_fonts "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(" | ".join(k+": "+v for k,v in d.items() if k.endswith("-sans")))' "$B/$1-fonts-cdp.json" 2>&1 | cut -c1-1500)"
	res lab_$1_fonts_mono_serif "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(" | ".join(k+": "+v for k,v in d.items() if k.startswith(("Latin","Bold","Arabic")) and not k.endswith("-sans")))' "$B/$1-fonts-cdp.json" 2>&1 | cut -c1-600)"
	res lab_$1_tofu "$(cut -c1-700 "$B/$1-fonts-js.json")"
}

step lab-prep
(timeout 7200 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
gsh "cat /etc/starfish-release; grep -E 'MemTotal|MemAvailable' /proc/meminfo" > "$B/guest.txt"
res guest_release "$(head -1 "$B/guest.txt")"
res lab_url_from_runner "$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$LAB_URL")"
gsh "ls /usr/share/fonts /usr/share/fonts/* 2>/dev/null | head -n 120; echo ====; ls /etc/fonts/conf.d 2>/dev/null; echo ====; (fc-list 2>/dev/null || echo no fc-list) | sed 's/:style.*//' | sort -u | head -n 80" > "$B/tv-fonts.txt"
res tv_fonts "$(grep -i -o -E '(droid[a-z-]*|tinos[a-z-]*|noto[a-z-]*|lg ?display[a-z-]*|lgsmarthei[a-z-]*|emoji[a-z-]*)\.(ttf|otf|ttc)' "$B/tv-fonts.txt" | sort -u | tr '\n' ' ' | cut -c1-900)"

step lab-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
t=$(date +%s); timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1
res install "rc=$? s=$(( $(date +%s) - t )) $(tail -1 "$B/ares-install.txt" | cut -c1-150)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res lab_result "install failed"; return 0; }
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"
step lab-warmup  # the app makes $T itself, owned by its own user
gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" > "$B/warmup-launch.txt"; sleep 50

# 1. fonts, TV's fontconfig
step lab-fonts-stock
start_lab stock
fonts_round stock

# 2. fonts, PR #22's fonts.conf (as the PR does: <app>/fonts.conf and FONTCONFIG_FILE in run.sh)
step lab-fonts-pr22
curl -s -m 30 -fL -o /tmp/pr22-fonts.conf "$PR22_CONF" && res pr22_conf_sha256 "$(sha256sum /tmp/pr22-fonts.conf | cut -c1-16)"
if [ -s /tmp/pr22-fonts.conf ]; then
	gsh_in "cat > $APPDIR/fonts.conf && chmod 644 $APPDIR/fonts.conf" < /tmp/pr22-fonts.conf
	gsh "cp $APPDIR/bin/run.sh /tmp/run.sh.orig; grep -q FONTCONFIG_FILE $APPDIR/bin/run.sh || sed -i 's#^export LANG=.*#&\nexport FONTCONFIG_FILE=\$D/fonts.conf#' $APPDIR/bin/run.sh; grep -n FONTCONFIG $APPDIR/bin/run.sh" > "$B/pr22-runsh.txt"
	res pr22_runsh "$(tr '\n' ' ' < "$B/pr22-runsh.txt")"
	start_lab pr22
	fonts_round pr22
	gsh "du -sh $APPDIR/data/cache/fontconfig $APPDIR/data/.cache/fontconfig 2>/dev/null; ls $APPDIR/data 2>/dev/null" > "$B/pr22-cache.txt"
	res pr22_cache "$(tr '\n' ' ' < "$B/pr22-cache.txt" | cut -c1-200)"
	gsh "cp /tmp/run.sh.orig $APPDIR/bin/run.sh; rm -f $APPDIR/fonts.conf"
else
	res lab_pr22 "fonts.conf download failed"
fi

# 3. media tests (stock fonts again)
step lab-media
start_lab media
# timeouts for the slow emulator: a test plays its clip for 6-30 s after a start that took up to 25 s there
for tst in codecs:40 avsync:120 p60:110 vp9:110 mse:120 iframe:120 youtube:60 two:110 audio_aac:80 audio_opus:80 fullscreen:45; do
	n=${tst%%:*}; to=${tst##*:}
	( sleep 8; shot lab-$n >/dev/null ) &
	timeout $((to + 20)) python3 /w/lab.py run $n $to > "$B/media-$n.json" 2>&1
	wait
	res lab_$n "$(cut -c1-700 "$B/media-$n.json")"
done
gsh "grep -a -E 'open|player|smp|direct|ndl|nohw|close|audio' $T/media.log | cut -c1-200 | tail -n 80" > "$B/media-log.txt"
gsh "grep -a -i -E 'cn-ndl|software|hardware|media' $T/browser.log | cut -c1-200 | tail -n 40" > "$B/media-browser.txt"

# 4. screen saver
step lab-screensaver
ssmon() { # $1 tag, $2 seconds: every 20 s the power state, foreground app and the video's time
	local t=$(date +%s)
	while [ $(( $(date +%s) - t )) -lt $2 ]; do
		p=$(gsh "luna-send -n 1 luna://com.webos.service.tvpower/power/getPowerState '{}'" | tr -d '\n ' | cut -c1-160)
		echo "t=$(( $(date +%s) - t )) fg=$(fg | tail -1) power=$p video=$(timeout 15 python3 /w/lab.py state 2>&1 | cut -c1-80)" >> "$B/ss-$1.txt"
		sleep 20
	done
}
start_lab ss
timeout 30 python3 /w/lab.py play > "$B/ss-play.txt" 2>&1
mark
ssmon playing 360
shot lab-ss-playing-6min >/dev/null
gsh "grep -a 'screensaver' $T/media.log | tail -n 30; echo ====; cat $T/playstate 2>/dev/null" > "$B/ss-playing-launcher.txt"
gsh "tail -n +$((ML + 1)) /var/log/messages | grep -a -i -E 'screensaver|screen saver|ScreenSaver' | cut -c1-260 | tail -n 40" > "$B/ss-playing-messages.txt"
timeout 30 python3 /w/lab.py pause > /dev/null 2>&1
mark
ssmon paused 360
shot lab-ss-paused-6min >/dev/null
gsh "grep -a 'screensaver' $T/media.log | tail -n 30; echo ====; cat $T/playstate 2>/dev/null" > "$B/ss-paused-launcher.txt"
gsh "tail -n +$((ML + 1)) /var/log/messages | grep -a -i -E 'screensaver|screen saver|ScreenSaver' | cut -c1-260 | tail -n 40" > "$B/ss-paused-messages.txt"
res ss_playing_fg "$(sed -E 's/.*fg=([^ ]*).*/\1/' "$B/ss-playing.txt" | uniq -c | tr '\n' ' ' | tr -s ' ')"
res ss_playing_power "$(grep -o -E '"(state|processing|powerState)":"[^"]*"' "$B/ss-playing.txt" | sort | uniq -c | tr '\n' ' ' | tr -s ' ')"
res ss_playing_video "$(sed -n '1p;$p' "$B/ss-playing.txt" | grep -o 'video=.*' | tr '\n' ' ')"
res ss_paused_fg "$(sed -E 's/.*fg=([^ ]*).*/\1/' "$B/ss-paused.txt" | uniq -c | tr '\n' ' ' | tr -s ' ')"
res ss_paused_power "$(grep -o -E '"(state|processing|powerState)":"[^"]*"' "$B/ss-paused.txt" | sort | uniq -c | tr '\n' ' ' | tr -s ' ')"
res ss_launcher "$(grep -a 'screensaver' "$B/ss-playing-launcher.txt" | sed 's/.*screensaver: //' | cut -c1-120 | tail -n 6 | tr '\n' '|')"
res ss_playstate "$(tail -1 "$B/ss-playing-launcher.txt")"
res ss_messages_playing "$(grep -a -c '' "$B/ss-playing-messages.txt") lines: $(tail -n 3 "$B/ss-playing-messages.txt" | sed -E 's/^.*\{\} //' | cut -c1-160 | tr '\n' '|')"
res ss_messages_paused "$(grep -a -c '' "$B/ss-paused-messages.txt") lines: $(tail -n 3 "$B/ss-paused-messages.txt" | sed -E 's/^.*\{\} //' | cut -c1-160 | tr '\n' '|')"

pkill -f 'ssh .*-L 9222' 2>/dev/null
stop_app
gsh "rm -f $T/media.opts $T/browser.flags"
res lab_result "done"
