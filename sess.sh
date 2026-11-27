# Sourced by run.sh (MODE=session). WebOS Chromium issue #42 (43UQ7500, webOS 7.6.0): "Continue where you left off"
# brings back no tabs. Sets that option, opens two tabs, ends the browser one way, starts it again and lists the tabs.
# Ways to end it: Chrome's own exit (Browser.close = the menu's Exit), webOS closing the app (closeByAppId, as the
# app switcher's close or memory pressure do), the remote's Back twice on a first page (patch 0057's exit). After
# each: Chrome's exit_type in Preferences, the Sessions folder, the launcher's "chrome exited" line.
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/session; mkdir -p "$B"
APPDIR=/media/developer/apps/usr/palm/applications/$ID
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
waitgone() { local t2=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t2 )) -lt 40 ]; do sleep 3; done; [ -z "$(procs)" ] && echo gone || echo "still running"; }
fwd() { pkill -f 'ssh .*-L 9222' 2>/dev/null; sleep 1
	(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } > "$B/fwd.log" 2>&1 &); sleep 4; }
start() { gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" >/dev/null; sleep 20; fwd
	local n=0; while [ $n -lt 30 ] && ! curl -s -m 3 http://127.0.0.1:9222/json/version >/dev/null; do sleep 3; n=$((n+1)); [ $((n % 8)) = 0 ] && fwd; done; sleep 8; }
prof() { # profile folder (run.sh: <app>/data, else /media/developer/<id>)
	gsh "for d in $APPDIR/data/profile /media/developer/$ID/profile; do [ -f \$d/Default/Preferences ] && { echo \$d; break; }; done" | grep ^/ | head -1; }
state() { local P=$(prof)
	gsh "grep -a -o -E '\"exit_type\":\"[A-Za-z]*\"' $P/Default/Preferences | tail -1; grep -a -o -E '\"restore_on_startup\":[0-9]+' $P/Default/Preferences | tail -1; ls -l $P/Default/Sessions 2>&1 | tail -n +2 | awk '{print \$5, \$NF}' | tr '\n' ' '; grep -a 'chrome exited' $T/media.log | tail -1" | tr '\n' ' '; }

step session-prep
(timeout 5400 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
( while sleep 45; do timeout 40 beanjar screensaver stop tv1 >/dev/null 2>&1; done ) & SSLOOP=$!
res guest_release "$(gsh 'head -1 /etc/starfish-release' | tail -1)"
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1; res install "rc=$? $(tail -1 "$B/ares-install.txt" | cut -c1-80)"
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"
gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" >/dev/null; sleep 40   # warm-up: makes $T and the profile
gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null; waitgone >/dev/null
gsh "echo --remote-debugging-port=9222 > $T/browser.flags; chmod 644 $T/browser.flags; chown \$(stat -c %u $T) $T/browser.flags"
start
res setpref "$(timeout 60 python3 /w/sess.py setpref 2>&1 | tail -1 | cut -c1-100)"

round() { # $1 name, $2 how to end
	step session-$1
	timeout 90 python3 /w/sess.py open >/dev/null 2>&1
	local before=$(timeout 30 python3 /w/sess.py tabs 2>&1 | tail -1)
	sleep 15   # Chrome saves the session a few seconds after a change
	case "$2" in
	exit)   timeout 30 python3 /w/sess.py close > "$B/$1-close.txt" 2>&1 ;;
	webos)  gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" > "$B/$1-close.txt" ;;
	back)   timeout 30 python3 /w/cdp.py eval "location.href='chrome://newtab'" >/dev/null 2>&1; sleep 4
	        beanjar remote press tv1 BACK >/dev/null 2>&1; sleep 2; beanjar remote press tv1 BACK >/dev/null 2>&1 ;;
	esac
	local gone=$(waitgone); [ "$gone" = gone ] || { gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null; waitgone >/dev/null; }
	local st=$(state)
	start
	local after=$(timeout 30 python3 /w/sess.py tabs 2>&1 | tail -1)
	shot session-$1 >/dev/null
	res sess_$1 "before=$before | end=$gone | $st | after=$after"
}
round exit exit
round webos webos
round back back
pkill -f 'ssh .*-L 9222' 2>/dev/null
gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
gsh "rm -f $T/browser.flags"
kill $SSLOOP 2>/dev/null
res session_result done
