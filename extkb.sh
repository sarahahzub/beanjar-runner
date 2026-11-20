# Sourced by run.sh (MODE=extkb) once the TV has booted (helpers res, step, el, gsh, gsh_in, shot, fg, press, SSH_ROOT
# come from run.sh). Does LG's on-screen keyboard open for a text field in an extension popup?
#   control: a textarea in a normal tab, pointer click (the keyboard should open: shows the check can see it)
#   pointer: the test extension's popup (extkb/), pointer click on its textarea
#   ok:      the same popup, DevTools puts focus on the textarea, then the remote's OK
# After each, the remote's OK once more: with the keyboard up that types its focused key into the field, which the
# field's own event log (window.LOG) shows. Screenshots in shots/extkb-*.png; logs/extkb/.
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/extkb; mkdir -p "$B"
EXTDIR=/media/developer/temp/extkb
EID=$(python3 -c "import hashlib,sys;print(''.join(chr(97+int(c,16)) for c in hashlib.sha256(sys.argv[1].encode()).hexdigest()[:32]))" "$EXTDIR")
res app_id "$ID"; res ext_id "$EID"
gsh true >/dev/null
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
launch() { gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'"; }
close() { gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'"; }
ce() { timeout 60 python3 /w/extcdp.py eval "$1" "$2" 2>&1 | tail -1; }
targets() { timeout 30 python3 /w/extcdp.py targets 2>&1 | tail -1; }
snap() { timeout 60 beanjar screenshot tv1 "$OUT/shots/extkb-$1.png" >>"$OUT/logs/screenshot.log" 2>&1; echo "$OUT/shots/extkb-$1.png"; }
rd() { python3 /w/regdiff.py "$@" 2>&1 | tail -1; }
ML=0
mark() { ML=$(gsh "wc -l < /var/log/messages" | tail -1 | tr -dc 0-9); }
msgs() { gsh "tail -n +$((ML + 1)) /var/log/messages 2>/dev/null | grep -i -E 'ime|keyboard|vkb|maliit|NL_VSC' | grep -v -E 'NL_SSG|HOMEHUB' | tail -12" > "$B/msgs-$1.txt"
	tr '\n' ' ' < "$B/msgs-$1.txt" | cut -c1-500; }
blog() { gsh "tail -n 60 $T/browser.log 2>/dev/null | grep -v -E 'dbus|LD_PRELOAD|create_wl_buffer'" > "$B/browser-$1.txt"; }
lit() { python3 -c "import sys;from PIL import Image,ImageStat;print(int(ImageStat.Stat(Image.open(sys.argv[1]).convert('L')).mean[0]))" "$1" 2>/dev/null || echo 0; }
ready() { # $1 name: the browser in front and drawn (not a black frame) before a test. LG's first-use overlay
	# (com.webos.app.firstuse-overlay) starts about 5 min after a fresh firmware boots and puts Home in front; a plain
	# launch then does not bring the browser back, so close the overlay and restart the browser.
	local i a s l t p
	for i in 1 2 3 4; do
		gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"com.webos.app.firstuse-overlay\"}'" >/dev/null
		a=$(fg | tail -1); s=$(snap "$1-ready"); l=$(lit "$s")
		[ "$a" = "$ID" ] && [ "$l" -gt 40 ] && { res "$1_ready" "try=$i fg=$a lit=$l"; return 0; }
		timeout 60 beanjar screensaver stop tv1 >/dev/null 2>&1
		close >/dev/null; t=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t )) -lt 30 ]; do sleep 3; done
		p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null
		pgrep -f 'ssh .*-L 9222' >/dev/null || (${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } >> "$B/ssh-L.log" 2>&1 &)
		launch >/dev/null; t=$(date +%s)
		while [ $(( $(date +%s) - t )) -lt 150 ]; do sleep 8; targets | grep -q '"page"' && break; done
		sleep 20
	done
	res "$1_ready" "NOT ready: fg=$a lit=$l"; return 1; }
ybox() { # box of the popup's yellow background in a screenshot
	python3 - "$1" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); w, h = im.size; px = im.load()
pts = [(x, y) for x in range(0, w, 2) for y in range(0, h, 2)
       if abs(px[x, y][0] - 255) < 8 and abs(px[x, y][1] - 212) < 8 and px[x, y][2] < 20]
print("%d %d %d %d" % (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts))
      if len(pts) > 3000 else "none")
EOF
}

step extkb-prep
(timeout 6000 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
# LG's screen saver comes back after about 4 minutes without input and turns the frame black: keep it away
( while sleep 45; do timeout 40 beanjar screensaver stop tv1 >/dev/null 2>&1; done ) &
SSLOOP=$!
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1; res screensaver_stop_rc $?
press HOME; sleep 8

step extkb-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
t=$(date +%s); timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1
res install "rc=$? s=$(( $(date +%s) - t )) $(tail -1 "$B/ares-install.txt" | cut -c1-150)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res extkb_result "install failed"; return 0; }
res version "$(gsh "grep -o '\"version\": *\"[^\"]*\"' $APPDIR/appinfo.json" | tail -1)"

step extkb-launch1
t=$(date +%s); launch > "$B/launch1.txt"
while [ -z "$(procs)" ] && [ $(( $(date +%s) - t )) -lt 240 ]; do sleep 10; done; sleep 45
TVT=$(gsh "for p in /proc/[0-9]*; do tr '\\0' '\\n' < \$p/cmdline 2>/dev/null | grep -m1 '^--load-extension=' ; done" | grep -m1 '^--load-extension=' | sed 's/^--load-extension=//')
res tvtools_path "${TVT:-not found}"
close >/dev/null; t=$(date +%s); while [ -n "$(procs)" ] && [ $(( $(date +%s) - t )) -lt 40 ]; do sleep 3; done
p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null

step extkb-extension
tar -C /w/extkb -cf - . | gsh_in "exec cat > /tmp/extkb.tar" >/dev/null
gsh "rm -rf $EXTDIR && mkdir -p $EXTDIR && tar -xf /tmp/extkb.tar -C $EXTDIR && chmod -R a+rX /media/developer/temp && ls -l $EXTDIR" > "$B/extdir.txt"
P=$(gsh "find $APPDIR/data /media/developer/$ID -path '*profile/Default/Preferences' 2>/dev/null | head -1" | grep ^/ | head -1)
res prefs "${P:-none}"
gsh "sed 's/\"pinned_extensions\":\[\([^]]*\)\]/\"pinned_extensions\":[\1,\"$EID\"]/' '$P' > /tmp/prefs.new && cat /tmp/prefs.new > '$P' && grep -o '\"pinned_extensions\":\[[^]]*\]' '$P'" > "$B/pin.txt"
res pinned "$(tail -1 "$B/pin.txt")"
gsh "printf '%s\n' --remote-debugging-port=9222 '--load-extension=$TVT,$EXTDIR' > $T/browser.flags && chmod 644 $T/browser.flags && cat $T/browser.flags" > "$B/flags.txt"
res flags "$(tr '\n' ' ' < "$B/flags.txt")"

step extkb-launch2
t=$(date +%s); launch > "$B/launch2.txt"
(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } > "$B/ssh-L.log" 2>&1 &)
ok=""; while [ $(( $(date +%s) - t )) -lt 300 ]; do sleep 8; targets | grep -q '"page"' && { ok=1; break; }; done
res cdp_ready_s "$(( $(date +%s) - t )) ok=${ok:-no}"
sleep 30; targets > "$B/targets-start.json"
res ext_loaded "$(grep -c "chrome-extension://$EID" "$B/targets-start.json")"
BASE=$(snap base)

step extkb-control
ready control
mark
res control_nav "$(timeout 60 python3 /w/extcdp.py nav "chrome://newtab" 'data:text/html,<body style="margin:0"><textarea id="t" style="width:900px;height:300px;font-size:30px;margin:40px"></textarea>' 2>&1 | tail -1)"
sleep 15; C0=$(snap control-0); res control_lit "$(lit "$C0")"
timeout 30 beanjar remote click tv1 400 350 >>"$OUT/logs/remote.log" 2>&1; sleep 6
C1=$(snap control-1)
res control_kb "$(rd "$C0" "$C1") msgs=[$(msgs control)]"
press ENTER; sleep 4; snap control-2 >/dev/null
res control_typed "$(ce "data:" "document.getElementById('t').value")"
press BACK; sleep 3; press BACK; sleep 3
blog control

# The extension's icon is pinned next to TV Tools. Its toolbar position is read from the first screenshot: the icon
# left of the extensions (puzzle) button, IX,IY below (1280x720 frame). The pointer click opens the popup, like a user.
IX=${IX:-1127}; IY=${IY:-63}
open_popup() { # $1 name: click the icon, then up to 40 s for the popup to be drawn
	timeout 30 beanjar remote click tv1 $IX $IY >>"$OUT/logs/remote.log" 2>&1
	local s b i
	for i in 1 2 3 4 5 6 7 8; do sleep 5; s=$(snap "$1-open"); b=$(ybox "$s"); [ "$b" != none ] && break; done
	res "$1_openpopup" "click=$IX,$IY after=$((i * 5))s targets=$(targets | grep -o "chrome-extension://$EID/popup.html" | head -1) box=$b lit=$(lit "$s")"
	echo "$s"; }

step extkb-pointer
ready pointer
mark
S=$(open_popup pointer | tail -1)
BOX=$(ybox "$S")
if [ "$BOX" != none ]; then
	set -- $BOX; cx=$(( ($1 + $3) / 2 )); cy=$(( ($2 + $4) / 2 + 10 ))
	timeout 30 beanjar remote click tv1 $cx $cy >>"$OUT/logs/remote.log" 2>&1; sleep 6
	P1=$(snap pointer-1)
	res pointer_kb "click=$cx,$cy $(rd "$S" "$P1") msgs=[$(msgs pointer)]"
	res pointer_log "$(ce "popup.html" "JSON.stringify({ae:(document.activeElement||{}).id, log:window.LOG})")"
	press ENTER; sleep 4; snap pointer-2 >/dev/null
	res pointer_typed "$(ce "popup.html" "JSON.stringify({v:document.getElementById('user').value, log:window.LOG.slice(-4)})")"
else
	res pointer_kb "no popup on screen"
fi
blog pointer
press BACK; sleep 3; ce "popup.html" "window.close()" >/dev/null; sleep 3

step extkb-ok
ready ok
mark
S=$(open_popup ok | tail -1)
res ok_focus "$(ce "popup.html" "(function(){var u=document.getElementById('user');u.focus();return (document.activeElement||{}).id})()")"
sleep 4; K0=$(snap ok-0)
res ok_after_focus "$(rd "$S" "$K0")"
press ENTER; sleep 6
K1=$(snap ok-1)
res ok_kb "$(rd "$K0" "$K1") msgs=[$(msgs ok)]"
res ok_log "$(ce "popup.html" "JSON.stringify({ae:(document.activeElement||{}).id, log:window.LOG})")"
press ENTER; sleep 4; snap ok-2 >/dev/null
res ok_typed "$(ce "popup.html" "JSON.stringify({v:document.getElementById('user').value, log:window.LOG.slice(-4)})")"
blog ok
press BACK; sleep 3

kill $SSLOOP 2>/dev/null
res extkb_result "done"
close >/dev/null; sleep 5
pkill -f 'ssh .*-L 9222' 2>/dev/null
