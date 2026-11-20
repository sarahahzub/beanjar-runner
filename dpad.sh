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

# ---------- 1. Back key
st back "page A -> link -> B, Back to A, Back on the first page (toast?), second Back (exit?)"
front; nav $W/a.html; base
FG=1 k DOWN ENTER; sleep 6
u=$(url); obs back_after_down_enter "$u"
case $u in *b.html*) ;; *) cf toB >/dev/null; FG=1 k ENTER; sleep 6; obs back_enter_with_cdp_focus "$(url)";; esac
FG=1 k BACK; sleep 5; obs back_after_back1 "$(url) | $(cdp pages)"
FG=1 k BACK; sleep 4; obs back_after_back2 "$(url) procs=[$(procs)]"
FG=1 KW=1 k BACK; FG=1 KW=1 k BACK; sleep 8; snap "$OUT/shots/back-after.png"
obs back_after_back4 "fg=$(fg | tail -1) procs=[$(procs)] $(gsh "grep -i -E 'toast|back' $T/media.log 2>/dev/null | tail -4" | tr '\n' ' ')"

# ---------- 2. Three-dot menu
st menu "UP into the toolbar, walk RIGHT, open the menu, every item DOWN+RIGHT+LEFT, BACK, then Exit"
front; nav $W/a.html; base
k UP UP UP
kn 14 RIGHT
goto "x>1235 and y0>30" RIGHT 6; goto "x>1235 and y0>30" LEFT 14
k ENTER
for i in $(seq 26); do k DOWN RIGHT LEFT; done
k BACK BACK
goto "x>1235 and y0>30" RIGHT 14
FG=1 k ENTER UP; FG=1 k ENTER; sleep 10
obs menu_exit "fg=$(fg | tail -1) procs=[$(procs)]"; snap "$OUT/shots/menu-after-exit.png"

# ---------- 3. Bookmark star
st star "reach the star, OK opens the bubble, walk it, OK, check Bookmarks"
front; nav $W/a.html; base
k UP
if [ $SCH = brave ]; then goto "160<x<205 and y0>30" RIGHT 14; else goto "700<x<1185 and w<50 and y0>30" RIGHT 14 || goto "700<x<1185 and w<50 and y0>30" LEFT 14; fi
k ENTER; sleep 2
k DOWN DOWN DOWN RIGHT RIGHT UP
obs star_before_ok "$(bmarks)"
k ENTER; sleep 6
obs star_after_ok "$(bmarks)"
nav $SCH://bookmarks; sleep 4; snap "$OUT/shots/star-bookmarks-page.png"

# ---------- 4. History page
st hist "brave://history: DOWN through entries, UP back to search/menu, sidebar, open entry, remove via its menu"
front; nav $SCH://history; sleep 4; base
obs hist_count_start "$(CDP_MATCH=history cdp eval "$HISTN")"
kn 8 DOWN; kn 10 UP; k LEFT LEFT RIGHT RIGHT
nav $SCH://history; sleep 4
kn 3 DOWN; k ENTER; sleep 6; obs hist_open_entry "$(url)"
nav $SCH://history; sleep 4
kn 3 DOWN; k RIGHT RIGHT ENTER DOWN ENTER; sleep 3
obs hist_count_after_remove "$(CDP_MATCH=history cdp eval "$HISTN")"
k BACK

# ---------- 5. Other browser parts
st tabs "tab strip: UP from the toolbar, walk, new-tab +, select a tab, close x"
front; nav $W/a.html; base
k UP UP UP UP; kn 4 RIGHT; kn 4 LEFT
goto "y1<44 and w<45 and x<700" RIGHT 6 && { k ENTER; sleep 5; obs tabs_after_plus "$(cdp pages)"; }
k UP; kn 3 LEFT; k ENTER; sleep 3; obs tabs_after_select "$(cdp pages)"
kn 2 RIGHT; k ENTER; sleep 3; obs tabs_after_close_try "$(cdp pages)"

st omni "address bar: reach it, DOWN into suggestions, ENTER"
front; nav $W/b.html; base
k UP; goto "w>300 and y0>30" RIGHT 10 || goto "w>300 and y0>30" LEFT 10
k ENTER; sleep 3; k BACK
k DOWN DOWN ENTER; sleep 6; obs omni_after_enter "$(url)"

st navbtn "back / forward / reload buttons"
front; nav $W/a.html; nav $W/b.html; base
k UP; goto "x<36 and y0>30" LEFT 14; k ENTER; sleep 5; obs navbtn_back "$(url)"
goto "36<=x<66 and y0>30" RIGHT 4; k ENTER; sleep 5; obs navbtn_forward "$(url)"
cdp eval "window.name='before-reload'" >/dev/null
goto "66<=x<100 and y0>30" RIGHT 4; k ENTER; sleep 6; obs navbtn_reload "$(cdp eval "performance.getEntriesByType('navigation')[0].type+' name='+window.name")"

if [ $SCH = brave ]; then
st shields "Shields lion panel: open, walk, OK on one control, close"
front; nav $W/a.html; base
k UP; goto "1040<x<1080 and y0>30" RIGHT 14 || goto "1040<x<1080 and y0>30" LEFT 14
k ENTER; sleep 4; kn 8 DOWN; k ENTER; sleep 3; kn 3 UP; k BACK; sleep 2; k BACK
fi

st sweep "from the menu button go LEFT one more each round, ENTER, walk the popup, BACK (extensions, TV Tools, ...)"
for r in 1 2 3 4; do
	front; nav $W/a.html; [ $r = 1 ] && base
	k UP; goto "x>1235 and y0>30" RIGHT 14
	kn $r LEFT; k ENTER; sleep 4; kn 4 DOWN; k ENTER; sleep 3; k BACK; sleep 2; k BACK
	obs sweep_$r "$(cdp pages)"
done

st ntp "New Tab page widgets"
front; nav $SCH://newtab; sleep 6; base
kn 6 DOWN; kn 3 RIGHT; kn 4 UP

st settings "Settings: sidebar, toggle, dropdown, sub-page and back"
front; nav $SCH://settings; sleep 8; base
kn 8 DOWN; kn 2 RIGHT; k ENTER; sleep 3; kn 4 DOWN; k ENTER; sleep 3; k BACK; sleep 2; k BACK
obs settings_url "$(CDP_MATCH=settings cdp eval location.href)"

st downloads "Downloads page"
front; nav $SCH://downloads; sleep 5; base
kn 3 DOWN; kn 3 UP

# ---------- 6. Page sub-elements
st walk "test page: DOWN through everything, then UP"
front; nav $W/t.html 8; cdp eval "document.activeElement&&document.activeElement.blur();scrollTo(0,0)" >/dev/null; base
kn 40 DOWN; kn 8 UP
st grid "links grid: CDP focus g5, then OK and arrows"
cf g5 >/dev/null; k ENTER RIGHT DOWN LEFT UP; obs grid "$(logv)"
st button "button A"; cf bA >/dev/null; k ENTER; obs button "$(logv)"
st alert "alert(): OK opens, arrows, OK closes"; cf bAlert >/dev/null; k ENTER; sleep 2; k LEFT RIGHT ENTER; sleep 2; obs alert "$(logv)"
st confirm "confirm(): RIGHT to Cancel?, OK"; cf bConfirm >/dev/null; k ENTER; sleep 2; k RIGHT ENTER; sleep 2; obs confirm "$(logv)"
st geo "geolocation permission prompt"; cf bGeo >/dev/null; k ENTER; sleep 4; k DOWN UP LEFT RIGHT ENTER; sleep 3; obs geo "$(logv)"
st notif "notification permission prompt"; cf bNotif >/dev/null; k ENTER; sleep 4; k DOWN UP LEFT RIGHT ENTER; sleep 3; obs notif "$(logv)"
st dialog "modal <dialog>"; cf bDlg >/dev/null; k ENTER; sleep 2; k RIGHT ENTER; obs dialog "$(logv)"
st text "text input: ENTER (keyboard?), ENTER, BACK, BACK"; cf txt >/dev/null; KW=3 k ENTER ENTER BACK BACK; obs text "$(logv)"
st textarea "textarea"; cf ta >/dev/null; KW=3 k ENTER BACK BACK; obs textarea "$(logv)"
st check "checkbox"; cf cb >/dev/null; k ENTER; obs check "$(logv)"
st radio "radio"; cf r1 >/dev/null; k ENTER RIGHT ENTER; obs radio "$(logv)"
st select "select: OK opens, DOWN DOWN, OK chooses"; cf sel >/dev/null; k ENTER; sleep 2; k DOWN DOWN ENTER; sleep 2; obs select "$(cdp eval "document.getElementById('sel').value") $(logv)"
st range "range slider"; cf rng >/dev/null; k RIGHT RIGHT LEFT; obs range "$(cdp eval "document.getElementById('rng').value") $(logv)"
st scroll "scrollable div: from the slider DOWN x4"; cf rng >/dev/null; k DOWN DOWN DOWN DOWN; obs scroll "scrollTop=$(cdp eval "document.getElementById('scr').scrollTop")"
st iframe "iframe links"; cdp eval "(function(){var f=document.getElementById('ifr');f.scrollIntoView({block:'center'});f.contentDocument.getElementById('f1').focus();return 1})()" >/dev/null
k ENTER RIGHT ENTER DOWN; obs iframe "$(logv)"
st video "video controls"; cf vid >/dev/null; k ENTER; sleep 3; k ENTER RIGHT RIGHT DOWN ENTER; sleep 2
obs video "$(cdp eval "(function(){var v=document.getElementById('vid');return JSON.stringify({paused:v.paused,t:v.currentTime,rs:v.readyState,err:v.error&&v.error.code,fs:!!document.fullscreenElement,src:v.currentSrc.slice(-9)})})()") $(logv)"
k BACK
st carousel "horizontal carousel"; cf c1 >/dev/null; kn 6 RIGHT; obs carousel "scrollLeft=$(cdp eval "document.getElementById('car').scrollLeft")"
st long "long page: DOWN with no element below"; cf c8 >/dev/null; kn 6 DOWN; obs long "$(logv)"

# ---------- 7. Edge cases: back to the toolbar with UP from deep in the page
st up "UP x12 from the bottom of the long page"; kn 12 UP; obs up_last_ui "$LASTFX"

res dpad_result "done"
close >/dev/null; sleep 5
gsh "grep -i -E 'toast|key|back' $T/media.log 2>/dev/null | tail -30" > "$B/media-keys.txt"
gsh "tail -c 40000 $T/media.log" > "$B/media.log.txt"
pkill -f 'ssh .*-L 9222' 2>/dev/null; pkill -f 'ssh .*-R 8000' 2>/dev/null
