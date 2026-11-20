# Sourced by run.sh (MODE=dpad) once the TV has booted (helpers res, step, el, gsh, gshl, shot, fg, press come from
# run.sh). Installs the browser IPK (/w/brave.ipk, hash checked by the workflow), then drives it with the remote
# D-pad only (UP DOWN LEFT RIGHT ENTER BACK) and takes a screenshot after every key press: shots/<step>-<n>.png.
# logs/dpad/keys.log has one line per key: shot name, key, Chrome UI focus ring found by fx.py (ui=), and the
# focused DOM element of the focused page target from CDP (ae=). CDP is used only to set up state (navigate,
# put DOM focus on a test element) and to read results, never to press the tested controls.
LS=luna://com.webos.applicationManager
ID=$(ar p /w/brave.ipk data.tar.gz | tar tzf - | sed -n 's#^\(\./\)\{0,1\}usr/palm/applications/\([^/]*\)/appinfo.json$#\2#p' | head -1)
T=/tmp/$ID
B=$OUT/logs/dpad; mkdir -p "$B"; FL=$B/keys.log; : > "$FL"
case $ID in com.brave.*) SCH=brave;; *) SCH=chrome;; esac
W=http://127.0.0.1:8000
res app_id "$ID"
gsh true >/dev/null
SSHB=${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ConnectTimeout=10 }
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[$(echo ${ID:0:1})]${ID:1}/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
launch() { gsh "luna-send -n 1 $LS/launch '{\"id\":\"$ID\"}'"; }
close() { gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'"; }
cdp() { timeout 120 python3 /w/cdp.py "$@" 2>&1 | tail -1; }
obs() { res "dpad_$1" "$(echo "$2" | tr '\n' ' ' | cut -c1-400)"; echo "   obs $1: $2" | cut -c1-500 >> "$FL"; }
cdp_wait() { local t=$(date +%s); while [ $(( $(date +%s) - t )) -lt ${1:-240} ]; do sleep 8; timeout 15 python3 /w/cdp.py list 2>/dev/null | grep -q '"page"' && return 0; done; return 1; }
snap() { timeout 60 beanjar screenshot tv1 "$1" >>"$OUT/logs/screenshot.log" 2>&1; }

CUR=setup; N=0; FXB=""; LASTFX=none
st() { CUR=$1; N=0; FXB=""; LASTFX=none; shift; echo "## t=$(el)s $CUR: $*" | tee -a "$FL"; }
base() { sleep 1; FXB=$B/base-$CUR.png; snap "$FXB"; cp "$FXB" "$OUT/shots/$CUR-00.png" 2>/dev/null; echo "$CUR-00 (baseline) ae=$(timeout 25 python3 /w/cdp.py ae 2>&1 | tail -1 | cut -c1-300)" >> "$FL"; }
k() { # press each key, wait KW s, screenshot, log UI focus ring and DOM focus
	local key nm f
	for key in "$@"; do
		N=$((N+1)); nm=$CUR-$(printf %02d $N)
		press "$key"; sleep "${KW:-2}"
		snap "$OUT/shots/$nm.png"
		LASTFX=none; [ -n "$FXB" ] && [ -s "$OUT/shots/$nm.png" ] && LASTFX=$(python3 /w/fx.py "$FXB" "$OUT/shots/$nm.png" 2>&1 | tail -1)
		f=""; [ "${FG:-0}" = 1 ] && f=" fg=$(fg | tail -1)"
		echo "$nm $key ui=[$LASTFX]$f ae=$(timeout 25 python3 /w/cdp.py ae 2>&1 | tail -1 | cut -c1-400)" >> "$FL"
	done; }
kn() { local n=$1 key=$2 i; for i in $(seq "$n"); do k "$key"; done; }
fxv() { echo "$LASTFX" | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }  # fxv x|w
goto() { # goto PRED KEY MAX: press KEY until the UI focus ring matches PRED (python, vars x w y0 y1)
	local pred=$1 key=${2:-RIGHT} max=${3:-14} i=0
	while :; do
		if python3 -c "import re,sys;m=re.match(r'x=(\d+) w=(\d+) y=(\d+)-(\d+)',sys.argv[1]);x,w,y0,y1=map(int,m.groups()) if m else (None,)*4;sys.exit(0 if m and ($pred) else 1)" "$LASTFX" 2>/dev/null; then
			echo "   goto [$pred]: yes at [$LASTFX] after $i" >> "$FL"; return 0; fi
		[ $i -ge "$max" ] && { echo "   goto [$pred]: NOT reached after $i, last [$LASTFX]" >> "$FL"; return 1; }
		k "$key"; i=$((i+1))
	done; }
front() { # bring the browser back to the front (relaunch if it exited)
	local a; a=$(fg | tail -1); [ "$a" = "$ID" ] && return 0
	echo "   front: fg was [$a] procs=[$(procs)], launching" >> "$FL"
	launch >/dev/null; cdp_wait 240; sleep 12; }
nav() { timeout 150 python3 /w/cdp.py nav "$1" "${2:-6}" > "$B/nav-$CUR-$N.json" 2>&1; sleep 2; }
cf() { cdp eval "(function(){var e=document.getElementById('$1');e.scrollIntoView({block:'center'});e.focus();return (document.activeElement||{}).id})()"; }
url() { cdp eval "location.href"; }
logv() { cdp eval "JSON.stringify({log:(window.LOG||[]).slice(-3),sy:Math.round(scrollY)})"; }
bmarks() { gsh "f=\$(find $APPDIR/data $T -name Bookmarks -path '*Default*' 2>/dev/null | head -1); echo \"\$f\"; grep -o '\"url\": *\"[^\"]*\"' \"\$f\" 2>/dev/null | head -5" | tr '\n' ' '; }
HISTN="(function(){try{var a=document.querySelector('history-app').shadowRoot;var l=a.querySelector('history-list').shadowRoot;return l.querySelectorAll('history-item').length}catch(e){return 'err '+e.message}})()"

step dpad-prep
(timeout 14000 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1; res screensaver_stop_rc $?
beanjar remote --help > "$B/remote-help.txt" 2>&1; beanjar remote press --help >> "$B/remote-help.txt" 2>&1
press HOME; sleep 8

step dpad-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
t=$(date +%s); timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1
res install "rc=$? s=$(( $(date +%s) - t )) $(tail -1 "$B/ares-install.txt" | cut -c1-150)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res dpad_result "install failed"; return 0; }

step dpad-web
(cd /w/web && exec python3 -m http.server 8000 --bind 127.0.0.1 > "$B/http.log" 2>&1 &)
(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -R 8000:127.0.0.1:8000 } > "$B/ssh-R.log" 2>&1 &)
sleep 5
res web_in_guest "$(gsh "curl -s --max-time 5 $W/a.html 2>/dev/null || wget -q -T 5 -O - $W/a.html 2>&1" | grep -o '<title>[^<]*' | head -1)"
ls -l /w/web >> "$B/http.log"

step dpad-launch
t=$(date +%s); launch > "$B/launch1.txt"
while [ -z "$(procs)" ] && [ $(( $(date +%s) - t )) -lt 240 ]; do sleep 10; done; sleep 40
shot dpad-launch1 >/dev/null
close >/dev/null; sleep 20
gsh "echo --remote-debugging-port=9222 > $T/browser.flags && chmod 644 $T/browser.flags"
t=$(date +%s); launch > "$B/launch2.txt"
(${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } > "$B/ssh-L.log" 2>&1 &)
cdp_wait 300; res cdp_ready_s "$(( $(date +%s) - t )) $(cdp pages)"
sleep 25; snap "$OUT/shots/launch-ready.png"
[ -n "$(procs)" ] || { res dpad_result "browser not running"; return 0; }

beanjar remote layout tv1 --json > "$B/remote-layout.json" 2>&1
fwd() { # the guest's sshd sometimes closes the long-lived forwards ("closed by remote host"): restart them
	pgrep -f 'ssh .*-L 9222' >/dev/null || { echo "   fwd: restarting -L 9222" >> "$FL"; (${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 } >> "$B/ssh-L.log" 2>&1 &); sleep 3; }
	pgrep -f 'ssh .*-R 8000' >/dev/null || { echo "   fwd: restarting -R 8000" >> "$FL"; (${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -R 8000:127.0.0.1:8000 } >> "$B/ssh-R.log" 2>&1 &); sleep 3; }; }
kh() { # hold one key MS ms, then the same shot/log as k
	N=$((N+1)); local nm=$CUR-$(printf %02d $N)
	timeout 30 beanjar remote press tv1 "$1" --hold "$2" >>"$OUT/logs/remote.log" 2>&1; sleep "${KW:-2}"
	snap "$OUT/shots/$nm.png"; echo "$nm $1(hold $2) fg=$(fg | tail -1) procs=[$(procs)] ae=$(timeout 25 python3 /w/cdp.py ae 2>&1 | tail -1 | cut -c1-300)" >> "$FL"; }
last() { echo "$OUT/shots/$CUR-$(printf %02d $N).png"; }
dif() { python3 /w/imgdiff.py "$1" "$2" 2>/dev/null || echo 1; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
fresh() { # close the browser and start it again: clean UI state for each section
	close >/dev/null; local t=$(date +%s) p
	while [ -n "$(procs)" ] && [ $(( $(date +%s) - t )) -lt 40 ]; do sleep 3; done
	p=$(procs); [ -n "$p" ] && { gsh "kill -9 $p" >/dev/null; sleep 3; }
	fwd; launch >/dev/null
	if ! cdp_wait 150; then
		echo "   fresh: no CDP after 150 s (procs=[$(procs)]), restarting" >> "$FL"
		close >/dev/null; sleep 10; p=$(procs); [ -n "$p" ] && gsh "kill -9 $p" >/dev/null; sleep 3
		fwd; launch >/dev/null; cdp_wait 200 || echo "   fresh: still no CDP" >> "$FL"
	fi
	sleep 10; echo "   fresh: $(cdp pages)" >> "$FL"; }
front() { [ "$(fg | tail -1)" = "$ID" ] && timeout 15 python3 /w/cdp.py list >/dev/null 2>&1 && return 0; fresh; }
toolbar() { goto "y0>=38 and y1<=90" UP 4; }  # UP until the focus ring is in the toolbar row
POS=$B/toolbar-positions.txt
pf() { k DOWN; timeout 25 python3 /w/cdp.py ae 2>/dev/null | grep -q '"focused"' || k DOWN; }  # after a CDP navigation the omnibox keeps focus: DOWN moves it into the page

# brave-parity (1.99.5855 vs 1.99.5856): the sections are in dpad-parity.sh
. /w/dpad-parity.sh
