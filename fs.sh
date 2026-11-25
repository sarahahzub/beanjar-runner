# Sourced by run.sh (MODE=fullscreen) once the TV has booted (helpers res, step, gsh, gsh_in, shot, fg, SSH_ROOT come
# from run.sh). WebOS Chromium issue #39 (43NANO756PR, webOS 6): fullscreen (F11 or the menu's button) goes back to
# the normal window a few seconds later, on every site. Installs /w/brave.ipk, then four rounds, each in a fresh
# browser on https://www.google.com: window fullscreen through CDP (= F11/menu), an F11 key press, the page's own
# requestFullscreen(), and window fullscreen again with the screen saver guard off (media.opts noss). fs.py records
# every change of the window state/size and the page's view over 90 s. Chrome logs the webOS shell's state events
# (--vmodule), so a state change sent by LSM shows up in browser.log.
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/fs; mkdir -p "$B"
res app_id "$ID"
ML=0
mark() { ML=$(gsh "wc -l < /var/log/messages" | tail -1 | tr -dc 0-9); }
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }

step fs-prep
(timeout 5400 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1; res screensaver_stop_rc $?
gsh "cat /etc/starfish-release; grep -E 'MemTotal|MemAvailable' /proc/meminfo" > "$B/guest.txt"
res guest_release "$(head -1 "$B/guest.txt")"

step fs-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
t=$(date +%s); timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1
res install "rc=$? s=$(( $(date +%s) - t )) $(tail -1 "$B/ares-install.txt" | cut -c1-150)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res fs_result "install failed"; return 0; }
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"
# the shell surface protocol the TV offers (patch 0002 drops client_size_changed from Chromium's listener)
gsh "ls /usr/share/wayland* /usr/share/webos-wayland* 2>/dev/null; grep -l -r 'wl_webos_shell_surface' /usr/share 2>/dev/null | head -3" > "$B/protocol-files.txt"
# Wayland protocol log (run 2): every webOS shell request and event in browser.log, to see whether LSM sends a
# state_changed before Chrome asks to leave fullscreen (round 1 showed Chrome's own "FullScreen -> NoState" request).
gsh "grep -q WAYLAND_DEBUG $APPDIR/bin/run.sh || sed -i '2i export WAYLAND_DEBUG=client' $APPDIR/bin/run.sh; sed -n 1,3p $APPDIR/bin/run.sh" > "$B/run-sh-head.txt"
# warm-up start: the app creates $T itself, owned by its own user (made by root, the app could not write there)
step fs-warmup
gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" > "$B/warmup-launch.txt"
sleep 60
res warmup "procs=[$(procs)] tdir=$(gsh "stat -c '%U:%G %a' $T" | tail -1)"

FLAGS='--remote-debugging-port=9222
--enable-logging=stderr
--vmodule=webos_shell_surface_wrapper=1,wayland_window_webos=1,wayland_window=1,wayland_toplevel_window=1,exclusive_access_manager=1,fullscreen_controller=1,browser_view=1'
round() { # $1 tag, $2 fs.py HOW, $3 media.opts content
	step fs-$1
	gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
	t2=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t2 )) -lt 30 ]; do sleep 3; done
	p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null
	sleep 5
	gsh "printf '%s\n' \"$FLAGS\" > $T/browser.flags; printf '%s\n' '$3' > $T/media.opts; chmod 644 $T/browser.flags $T/media.opts; chown -R \$(stat -c %u $T) $T/browser.flags $T/media.opts 2>/dev/null; true"
	timeout 60 beanjar screensaver stop tv1 >/dev/null 2>&1
	mark
	gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'" > "$B/$1-launch.txt"
	sleep 45
	pkill -f 'ssh .*-L 9222' 2>/dev/null; sleep 1
	(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } > "$B/$1-fwd.log" 2>&1 &)
	sleep 5
	timeout 90 python3 /w/cdp.py nav "https://www.google.com/" 20 > "$B/$1-nav.json" 2>&1
	shot fs-$1-before >/dev/null
	gsh "wc -l < $T/browser.log" > /tmp/bl0; BL=$(tail -1 /tmp/bl0 | tr -dc 0-9)
	(timeout 150 python3 /w/fs.py "$2" 90 > "$B/$1-fs.json" 2>&1 &)
	( for i in $(seq 1 18); do echo "$(date +%T) $(fg | tail -1)"; sleep 5; done > "$B/$1-fg.txt" ) &
	FGL=$!
	sleep 6; shot fs-$1-6s >/dev/null
	sleep 24; shot fs-$1-30s >/dev/null
	sleep 60; shot fs-$1-90s >/dev/null
	wait $FGL 2>/dev/null
	t2=$(date +%s); while [ ! -s "$B/$1-fs.json" ] && [ $(( $(date +%s) - t2 )) -lt 60 ]; do sleep 3; done
	pkill -f 'ssh .*-L 9222' 2>/dev/null
	gsh "tail -n +$((${BL:-0} + 1)) $T/browser.log | grep -a -v -E 'create_wl_buffer|dbus' | grep -a -i -E 'state|fullscreen|exclusive|activation|exposed|maximiz|minimiz|bounds|webos_shell|wayland_window' | cut -c1-300 | head -n 150" > "$B/$1-browser-state.txt"
	gsh "tail -n +$((ML + 1)) /var/log/messages 2>/dev/null | grep -a -E 'set_state|requestStateChange|sendState|setState' | cut -c1-260" > "$B/$1-lsm-state.txt"
	gsh "tail -n +$((${BL:-0} + 1)) $T/browser.log | grep -a -v -E 'create_wl_buffer|dbus' | tail -n 80" > "$B/$1-browser-tail.txt"
	gsh "tail -n +$((${BL:-0} + 1)) $T/browser.log | grep -a -E 'wl_webos_shell_surface|wl_shell_surface|wl_webos_shell@|xdg_toplevel' | grep -a -v -E 'set_property|ping|pong' | cut -c1-200 | head -n 200" > "$B/$1-wayland.txt"
	gsh "grep -a -E 'screensaver' $T/media.log | tail -n 20" > "$B/$1-screensaver.txt"
	gsh "tail -n +$((ML + 1)) /var/log/messages 2>/dev/null | grep -a -i -E '$ID|LSM|surface|fullscreen|screensaver|keyfilter|foreground|wam' | cut -c1-300 | tail -n 120" > "$B/$1-messages.txt"
	res fs_$1 "$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print("no result", open(sys.argv[1]).read()[:200].replace("\n"," ")); sys.exit()
ch=" | ".join("%s %s %s i=%s fs=%s v=%s" % (x["t"],x.get("win"),x.get("size"),x.get("i"),x.get("fs"),x.get("v")) for x in d.get("changes",[])[:8])
print("call=%s on=%s left=%s :: %s :: events %s" % (str(d.get("call"))[:60], d.get("fullscreen_at_s"), d.get("left_fullscreen_at_s"), ch, "; ".join(d.get("page_events",[])[:8])))' "$B/$1-fs.json" | cut -c1-900)"
	res fs_$1_lsm_states "$(grep -a -o -E 'State changed\([A-Z]+\)|state=[0-9]+' "$B/$1-browser-state.txt" | tr '\n' ' ' | cut -c1-300)"
	res fs_$1_wayland "$(grep -a -E 'set_state|state_changed|state_about_to_change|exposed|close' "$B/$1-wayland.txt" | sed -E 's/^\[ *([0-9.]+)\] */\1 /' | head -n 12 | tr '\n' '|' | cut -c1-900)"
	res fs_$1_fg "$(cut -d' ' -f2 "$B/$1-fg.txt" | uniq -c | tr '\n' ' ' | tr -s ' ')"
}
round window window ''
round key key ''
round element element ''
round window-noss window 'noss'
gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
gsh "rm -f $T/media.opts $T/browser.flags"
res fs_result "window_left=$(grep -m1 '^fs_window=' "$R" | grep -o 'left=[^ ]*') key_left=$(grep -m1 '^fs_key=' "$R" | grep -o 'left=[^ ]*') element_left=$(grep -m1 '^fs_element=' "$R" | grep -o 'left=[^ ]*') noss_left=$(grep -m1 '^fs_window-noss=' "$R" | grep -o 'left=[^ ]*')"
