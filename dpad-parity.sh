# Sourced by dpad.sh (MODE=dpad) after its setup (install, web server, launch with CDP, helpers).
# Parity run (brave-parity, 1.99.5855 vs 1.99.5856): the --no-sandbox bar, Back / Back-to-exit, the app menu
# (default + the cn-menu A/B switches of 5856), menu Exit, the bookmark bubble, permission prompt, history UP,
# Brave New Tab page UP and focus ring, the Shields panel. SUITE=smoke (webOS 4.4) does a short subset.
VER=$(ar p /w/brave.ipk data.tar.gz | tar xzf - -O "$(ar p /w/brave.ipk data.tar.gz | tar tzf - | grep -m1 'applications/[^/]*/appinfo.json$')" | grep -o '"version": *"[^"]*"' | cut -d'"' -f4)
res version "$VER"
flags() { # flags LINE... : browser.flags = CDP port + the given lines
	gsh "printf '%s\n' --remote-debugging-port=9222 $* > $T/browser.flags && chmod 644 $T/browser.flags"; }
blog() { gsh "cat $T/browser.log 2>/dev/null" > "$B/browser-$1.log"; grep -c . "$B/browser-$1.log" | sed "s/^/   browser.log $1 lines: /" >> "$FL"; }
mlog() { gsh "tail -c 20000 $T/media.log 2>/dev/null" > "$B/media-$1.log"; }
ringrow() { python3 -c "import re,sys;m=re.match(r'x=(\d+) w=(\d+) y=(\d+)-(\d+)',sys.argv[1]);print('none' if not m else ('toolbar' if int(m.group(3))>=38 and int(m.group(4))<=90 else ('tabs' if int(m.group(4))<38 else ('bar' if int(m.group(4))<=175 else 'page'))))" "$LASTFX" 2>/dev/null || echo none; }

# ---------- 0. --no-sandbox bar (5856: Hide; from the 3rd showing also Don't show again)
st bar "--no-sandbox bar: fresh start (3rd showing), toolbar, DOWN, DOWN, OK on the lower button"
fresh; base; snap "$OUT/shots/bar-start.png"
toolbar; obs bar_toolbar "$LASTFX"
k DOWN; obs bar_down1 "$(ringrow) $LASTFX"
k DOWN; obs bar_down2 "$(ringrow) $LASTFX"
k UP; obs bar_up "$(ringrow) $LASTFX"
k DOWN; k ENTER; sleep 3; obs bar_after_ok "$(gsh "grep -o '\"chromium_native\":{[^}]*}' $APPDIR/data/profile/'Local State' $T/profile/'Local State' 2>/dev/null" | tr '\n' ' ')"
fresh; base; snap "$OUT/shots/bar-next-start.png"; obs bar_next_start "$(gsh "grep -o '\"chromium_native\":{[^}]*}' $APPDIR/data/profile/'Local State' 2>/dev/null")"

# ---------- 1. Back
st back "a.html -> link -> b.html; BACK (history back?); BACK on the first page: toast, BACK again within 3 s: exit"
fresh; nav $W/a.html; base; pf
cf toB >/dev/null; FG=1 k ENTER; sleep 5; obs back_on_B "$(url)"
FG=1 k BACK; sleep 3; obs back_after_back "$(url) row=$(ringrow)"
fresh; base
KW=1 k BACK; snap "$OUT/shots/back-toast-1s.png"; obs back_first "fg=$(fg | tail -1) procs=[$(procs)]"
KW=1 k BACK; sleep 8; obs back_second "fg=$(fg | tail -1) procs=[$(procs)]"; snap "$OUT/shots/back-after-second.png"
mlog back; obs back_media "$(grep -E 'quitting|toast|SIGTERM|SIGKILL|chrome exited' "$B/media-back.log" | tail -4 | tr '\n' ';')"

# ---------- 2. App menu: default and the A/B switches (5856 only)
VARS="default"; [ "$VER" = 1.99.5856 ] && VARS="default --cn-menu-no-bubble --cn-menu-opaque --cn-menu-no-fit"
[ "${SUITE:-full}" = smoke ] && VARS="default"
for v in $VARS; do
	n=${v#--cn-menu-}
	st menu-$n "menu with ${v}: open (diff to closed), DOWN x3, BACK"
	if [ "$v" = default ]; then flags; else flags "$v"; fi
	fresh; nav $W/a.html; base; pf; toolbar; goto "x>1235 and y0>=38" LEFT 4
	MC=$(last); [ -s "$MC" ] || MC=$FXB
	k ENTER; sleep 3; obs menu_${n}_open_diff "$(dif "$MC" "$(last)")"
	kn 3 DOWN; obs menu_${n}_down3_diff "$(dif "$MC" "$(last)")"
	k BACK; sleep 2
	blog menu-$n; obs menu_${n}_log "$(grep 'cn-menu:' "$B/browser-menu-$n.log" | head -12 | cut -c1-260 | tr '\n' ';')"
done
flags

# ---------- 3. Menu Exit
st exit "menu: OK opens, UP wraps to Exit, OK"
fresh; nav $W/a.html; base; pf; toolbar; goto "x>1235 and y0>=38" LEFT 4; k ENTER; sleep 2
FG=1 k UP; FG=1 k ENTER; sleep 12; obs menu_exit "fg=$(fg | tail -1) procs=[$(procs)]"; snap "$OUT/shots/exit-after.png"
mlog exit; obs exit_media "$(grep -E 'quitting|SIGTERM|SIGKILL|chrome exited' "$B/media-exit.log" | tail -4 | tr '\n' ';')"

if [ "${SUITE:-full}" = smoke ]; then
	st netlog "3 min on the New Tab page with a net log (background requests)"
	flags "--log-net-log=$T/netlog.json"; fresh; sleep 180; close >/dev/null; sleep 10
	gsh "cat $T/netlog.json 2>/dev/null" > "$B/netlog.json"
	obs netlog_hosts "$(grep -o '"url":"https\?://[^/"]*' "$B/netlog.json" | sed 's/"url":"//' | sort | uniq -c | sort -rn | head -25 | tr '\n' ';')"
	flags
	fresh; base; snap "$OUT/shots/smoke-ntp.png"; obs gpu "$(timeout 60 python3 /w/cdp.py gpu 2>&1 | tail -1 | cut -c1-300)"
	blog smoke; obs smoke_cngpu "$(grep -c 'cn-gpu:' "$B/browser-smoke.log")"
	res dpad_result "done (smoke)"; close >/dev/null; sleep 5
	gsh "ls -la $APPDIR/data/lastlog/ 2>&1; cat $APPDIR/data/lastlog/crash.txt 2>/dev/null" > "$B/lastlog-ls.txt"
	pkill -f 'ssh .*-L 9222' 2>/dev/null; pkill -f 'ssh .*-R 8000' 2>/dev/null
	return 0
fi

# ---------- 4. Bookmark star bubble
st star "reach the star, OK opens the bubble, DOWN x3, UP, RIGHT, LEFT (focus moves?), BACK"
fresh; nav $W/a.html; base; pf; toolbar
SP="160<x<205 and y0>=38"; goto "$SP" RIGHT 16 || goto "$SP" LEFT 16; obs star_reached "$LASTFX"
k ENTER; sleep 3; S0=$(last); obs star_bubble_diff "$(dif "$FXB" "$S0")"
for kk in DOWN DOWN DOWN UP RIGHT LEFT; do p=$(last); k $kk; obs star_$N "$kk diff_prev=$(dif "$p" "$(last)") ui=$LASTFX"; done
k BACK; sleep 2

# ---------- 5. Permission prompt (geolocation)
st geo "permission prompt: CDP focus bGeo, OK, then DOWN / RIGHT / LEFT / OK"
fresh; nav $W/t.html 6; base; pf; cf bGeo >/dev/null; k ENTER; sleep 5; G0=$(last)
for kk in DOWN RIGHT LEFT; do p=$(last); k $kk; obs geo_$N "$kk diff_prev=$(dif "$p" "$(last)") ui=$LASTFX"; done
k ENTER; sleep 3; obs geo_after_ok "$(logv) perm=$(cdp eval "navigator.permissions.query({name:'geolocation'}).then(p=>p.state)")"

# ---------- 6. History: UP from the entries
st history "history: DOWN x3 into the entries, UP x6 (search box, then toolbar?), BACK"
nav $W/b.html; nav $SCH://history 6; base; k DOWN; kn 3 DOWN
for i in 1 2 3 4 5 6; do k UP; obs hist_up$i "$(ringrow) ae=$(timeout 25 python3 /w/cdp.py ae 2>&1 | tail -1 | cut -c1-120)"; done
nav $SCH://history 6; base; k DOWN DOWN; k BACK; sleep 3; obs hist_back "$(url)"

# ---------- 7. Brave New Tab page
st ntp "New Tab page: DOWN x2 (top site), focus ring?, UP x4 (toolbar?)"
fresh; base; kn 2 DOWN; obs ntp_down "$(ringrow) $LASTFX ae=$(timeout 25 python3 /w/cdp.py ae 2>&1 | tail -1 | cut -c1-160)"
for i in 1 2 3 4; do k UP; obs ntp_up$i "$(ringrow) $LASTFX"; done

# ---------- 8. Shields panel
st shields "Shields: open from the toolbar, DOWN x6 with the panel's focused element, BACK"
fresh; nav $W/a.html; base; pf; toolbar; goto "1040<x<1080 and y0>=38" LEFT 16; obs shields_reached "$LASTFX"
k ENTER; sleep 5; obs shields_panel "$(cdp pages | cut -c1-300)"
for i in 1 2 3 4 5 6; do k DOWN; obs shields_down$i "$(CDP_MATCH=shields timeout 25 python3 /w/cdp.py eval "(function(){let e=document.activeElement;while(e&&e.shadowRoot&&e.shadowRoot.activeElement)e=e.shadowRoot.activeElement;return e?(e.tagName+'#'+e.id+' '+(e.getAttribute('aria-label')||e.textContent||'').trim().slice(0,40)):'none'})()" 2>&1 | tail -1)"; done
k BACK; sleep 2; obs shields_after_back "$(cdp pages | cut -c1-200)"

res dpad_result "done"
gsh "tail -c 40000 $T/media.log" > "$B/media.log.txt"; blog end
close >/dev/null; sleep 5
pkill -f 'ssh .*-L 9222' 2>/dev/null; pkill -f 'ssh .*-R 8000' 2>/dev/null
