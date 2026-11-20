# Sourced by run.sh (MODE=brave) once the TV has booted: helpers res, step, el, gsh, gshl, gsh_in, shot, fg, press,
# vmstat_line and VMDIR, OUT come from run.sh. Installs the Brave IPK (/w/brave.ipk, hash checked by the workflow),
# launches it, and checks window, GPU, page loads, Shields, remote, memory, video and close. Every wait is bounded.
now() { date +%s.%N; }
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
LS=luna://com.webos.applicationManager
ID=com.brave.browser
T=/tmp/$ID
B=$OUT/logs/brave; mkdir -p "$B"
gsh true >/dev/null  # sets SSH_ROOT in this shell
SSHB=${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ConnectTimeout=10 }
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[c]om.brave.browser/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
pss() { # total PSS (kB) of the Brave processes; under qemu-user each is a qemu-arm process (includes the translator)
	gsh "t=0; n=0; for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[c]om.brave.browser/browser/chrome' || continue; k=\$(awk '/^Pss:/{s+=\$2} END{print s+0}' \$p/smaps_rollup 2>/dev/null); t=\$((t+k)); n=\$((n+1)); done; echo procs=\$n pss_kb=\$t \$(grep MemAvailable /proc/meminfo | tr -s ' ')" | tail -1; }
blogs() { # copy the app's logs out (tag)
	gsh "cd $T 2>/dev/null && for f in media.log browser.log gpuprobe.result media.opts browser.flags; do [ -f \$f ] && { echo \"==== \$f\"; tail -c 60000 \$f; }; done" > "$B/logs-$1.txt"; }
launch() { gsh "luna-send -n 1 $LS/launch '$1'"; }
close() { gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'"; }
cdp() { timeout 300 python3 /w/cdp.py "$@" 2>&1 | tail -1; }

step brave-prep
(timeout 5400 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1; res screensaver_stop_rc $?
press HOME; sleep 10; shot home >/dev/null
gsh "cat /etc/starfish-release; uname -m; ls /lib/libc-* /lib/libc.so.6 2>&1; /lib/libc.so.6 2>&1 | head -1; grep -E 'MemTotal|MemAvailable|SwapTotal' /proc/meminfo; df -h /media/developer /tmp 2>/dev/null" > "$B/guest.txt"
res guest_release "$(head -1 "$B/guest.txt")"
res guest_glibc "$(grep -o -m1 'version [0-9.]*' "$B/guest.txt")"
gsh "luna-send -n 1 luna://com.webos.service.tv.systemproperty/getSystemInfo '{\"keys\":[\"modelName\",\"firmwareVersion\",\"sdkVersion\",\"boardType\"]}'" > "$B/sysinfo.json"
res sysinfo "$(tr -d '\n' < "$B/sysinfo.json" | cut -c1-300)"

# the IPK on the host side, for the static library/symbol check
mkdir -p /tmp/ipkx && (cd /tmp/ipkx && ar x /w/brave.ipk && tar xzf data.tar.gz ./usr/palm/applications/$ID/browser/chrome ./usr/palm/applications/$ID/lib ./usr/palm/applications/$ID/bin)
AX=/tmp/ipkx/usr/palm/applications/$ID

step brave-install
t=$(now)
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1; res npm_rc $?
timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1; rc=$?
res install_ares "rc=$rc s=$(dt "$t" "$(now)") $(tail -2 "$B/ares-install.txt" | tr '\n' ' ' | cut -c1-200)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
if [ -z "$APPDIR" ]; then # fallback: root appInstallService/dev/install from the appstore disk
	t=$(now)
	gsh "mkdir -p /media/developer/temp" >/dev/null
	timeout 900 $SSHB "exec cat > /media/developer/temp/brave.ipk" < /w/brave.ipk; res ipk_copy_rc $?
	gshl "luna-send -n 30 -w 600000 luna://com.webos.appInstallService/dev/install '{\"id\":\"$ID\",\"ipkUrl\":\"/media/developer/temp/brave.ipk\",\"subscribe\":true}'" > "$B/dev-install.txt"
	res install_dev "s=$(dt "$t" "$(now)") $(tail -c 300 "$B/dev-install.txt" | tr '\n' ' ')"
	APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
	gsh "rm -f /media/developer/temp/brave.ipk" >/dev/null
fi
res appdir "${APPDIR:-not installed}"
gsh "luna-send -n 1 $LS/getAppInfo '{\"id\":\"$ID\"}'" > "$B/appinfo-sam.json"
res sam_appinfo "$(tr -d '\n' < "$B/appinfo-sam.json" | grep -o '"version": *"[^"]*"\|"returnValue": *[a-z]*' | tr '\n' ' ')"
[ -n "$APPDIR" ] || { res brave_result "install failed"; return 0; }
gsh "ls -l $APPDIR $APPDIR/bin; cat $APPDIR/bin/requires; du -sh $APPDIR" > "$B/appdir.txt"

step brave-symcheck
mkdir -p /tmp/groot
fetchlibs() { # fetch named libraries from the guest's /lib and /usr/lib (symlinks followed) into /tmp/groot
	local l=""; for n in "$@"; do l="$l lib/$n usr/lib/$n"; done
	timeout 300 $SSHB "exec </dev/null; cd / && tar chf - \$(ls -d $l 2>/dev/null)" 2>/dev/null | tar xf - -C /tmp/groot 2>/dev/null
}
N1=$( (readelf -d "$AX/browser/chrome"; for f in "$AX"/lib/*.so; do readelf -d "$f"; done) | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | sort -u)
fetchlibs $N1 libEGL.so.1 libGLESv2.so.2 libwayland-egl.so.1
N2=$(for f in /tmp/groot/lib/* /tmp/groot/usr/lib/*; do readelf -d "$f" 2>/dev/null; done | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | sort -u)
fetchlibs $N2
ls /tmp/groot/lib /tmp/groot/usr/lib > "$B/guest-libs.txt" 2>&1
python3 /w/symcheck.py "$AX" /tmp/groot > "$B/symcheck.txt" 2>&1
res symcheck "$(tail -1 "$B/symcheck.txt"); $(head -1 "$B/symcheck.txt")"
for l in libwayland-client.so.0 libEGL.so.1 libGLESv2.so.2 libglib-2.0.so.0; do
	f=$(ls /tmp/groot/usr/lib/$l /tmp/groot/lib/$l 2>/dev/null | head -1); echo "$l -> $(readlink -f "$f" | xargs -r basename)"
done > "$B/guest-lib-versions.txt"
res guest_libs "$(tr '\n' ' ' < "$B/guest-lib-versions.txt")"

step brave-launch1
res mem_before "$(gsh "grep MemAvailable /proc/meminfo | tr -s ' '" | tail -1)"
t0=$(now)
launch "{\"id\":\"$ID\"}" > "$B/launch1.txt"
res launch1_call "$(tr -d '\n' < "$B/launch1.txt" | cut -c1-200)"
first_proc=""; i=0
while [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 300 ]; do
	sleep 15; i=$((i+1)); e=$(dt "$t0" "$(now)")
	p=$(procs); [ -z "$first_proc" ] && [ -n "$p" ] && first_proc=$e
	echo "t=$e procs=[$p] fg=[$(fg | tail -1)] $(gsh "tail -c 400 $T/media.log 2>/dev/null | tail -2 | tr '\n' ' '" | tail -1 | cut -c1-220)" | tee -a "$B/launch1-poll.txt"
	shot "launch1-$(printf %03d "${e%.*}")s" >/dev/null
	[ -z "$p" ] && [ "${e%.*}" -gt 120 ] && { echo "no Brave process at $e s" >> "$B/launch1-poll.txt"; break; }
done
res launch1 "first_chrome_proc_s=${first_proc:-none} procs_at_end=[$(procs)] fg=[$(fg | tail -1)]"
blogs launch1
res compat "$(grep -m1 'compat:' "$B/logs-launch1.txt")"
res gpu_line "$(grep -m1 -E '^.{0,40}gpu:|OK, the GPU|GPU probe' "$B/logs-launch1.txt" | cut -c1-200)"
res ndl_line "$(grep -m1 'ndl api' "$B/logs-launch1.txt" | cut -c1-200)"
res mem_launch1 "$(pss)"
gsh "ls -la $T; find $APPDIR/data $T -maxdepth 4 \\( -iname '*crash*' -o -name '*.dmp' -o -name 'core*' \\) 2>/dev/null; dmesg | tail -40" > "$B/after-launch1.txt"

if [ -z "$(procs)" ]; then
	res brave_result "Brave not running after launch 1"
	gsh "tail -60 /var/log/messages 2>/dev/null; journalctl -n 80 --no-pager 2>/dev/null" > "$B/syslog.txt"
	return 0
fi

step brave-cdp-setup
close > "$B/close1.txt"; sleep 20
res close1 "procs_after_20s=[$(procs)]"
gsh "[ -d $T ] && echo --remote-debugging-port=9222 > $T/browser.flags && chmod 644 $T/browser.flags; ls -l $T" > "$B/flags.txt"
t0=$(now)
launch "{\"id\":\"$ID\"}" > "$B/launch2.txt"
FWD=${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 }
($FWD >"$B/ssh-forward.log" 2>&1 &)
cdp_s=""
while [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 300 ]; do
	sleep 10; e=$(dt "$t0" "$(now)")
	if timeout 15 python3 /w/cdp.py list > /tmp/l.json 2>&1 && grep -q '"page"' /tmp/l.json; then cdp_s=$e; break; fi
	[ $(( ${e%.*} % 30 )) -lt 10 ] && shot "launch2-$(printf %03d "${e%.*}")s" >/dev/null
done
res launch2_cdp "page_target_s=${cdp_s:-none} $(head -c 300 /tmp/l.json)"
shot launch2-ready >/dev/null
if [ -z "$cdp_s" ]; then
	res cdp "unavailable: $(tail -2 "$B/ssh-forward.log" | tr '\n' ' ') guest: $(gsh "curl -s --max-time 5 http://127.0.0.1:9222/json/version 2>&1 || wget -q -O - http://127.0.0.1:9222/json/version 2>&1" | tr '\n' ' ' | cut -c1-200)"
fi
res cdp_version "$(cdp version | cut -c1-300)"

step brave-back-first
press BACK; sleep 2; shot back-first-2s >/dev/null; sleep 4; shot back-first-6s >/dev/null
res back_first_page "procs=[$(procs)] $(gsh "grep -i -E 'toast|exit' $T/media.log 2>/dev/null | tail -2 | tr '\n' ' '" | tail -1 | cut -c1-200)"
if [ -z "$(procs)" ]; then # Back exited: start again for the other checks
	t0=$(now); launch "{\"id\":\"$ID\"}" > /dev/null
	while [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 300 ]; do sleep 10; python3 /w/cdp.py list 2>/dev/null | grep -q '"page"' && break; done
	res relaunch_after_back "s=$(dt "$t0" "$(now)")"
fi
sleep 20; res mem_idle "$(pss)"

step brave-gpu
cdp gpu > "$B/gpu.json"; res gpu_cdp "$(head -c 600 "$B/gpu.json")"

step brave-pages
cdp nav https://en.wikipedia.org/wiki/Television 120 > "$B/nav-wikipedia.json"
res wikipedia "$(head -c 500 "$B/nav-wikipedia.json")"
shot wikipedia >/dev/null
# remote: focus moves and Enter follows a link (spatial navigation), Back returns
before=$(cdp eval "location.href")
for k in DOWN DOWN DOWN; do press $k; sleep 3; done
res focus_after_down "$(cdp eval "(document.activeElement||{}).tagName+' '+((document.activeElement||{}).href||(document.activeElement||{}).id||'')" | cut -c1-200)"
shot remote-down3 >/dev/null
press ENTER; sleep 40
after=$(cdp eval "location.href"); shot remote-enter >/dev/null
press BACK; sleep 30
back=$(cdp eval "location.href"); shot remote-back >/dev/null
res remote "before=$before after_enter=$after after_back=$back"

cdp nav https://www.bbc.com/ 150 > "$B/nav-bbc.json"
res bbc "$(head -c 500 "$B/nav-bbc.json")"
shot bbc >/dev/null
res mem_bbc "$(pss)"

step brave-video
cdp nav "https://www.youtube.com/watch?v=aqz-KE-bpKQ" 90 > "$B/nav-youtube.json"
res youtube_nav "$(head -c 400 "$B/nav-youtube.json")"
press ENTER; sleep 30  # remote OK on the player (a play key press, not a CAPTCHA)
v1=$(cdp eval "(function(){var v=document.querySelector('video');var t=(document.body||{}).innerText||'';return JSON.stringify({video:!!v,paused:v&&v.paused,t:v&&v.currentTime,rs:v&&v.readyState,w:v&&v.videoWidth,h:v&&v.videoHeight,err:v&&v.error&&v.error.code,bot:/not a bot|confirm you/i.test(t)})})()")
shot youtube-1 >/dev/null; sleep 20
v2=$(cdp eval "(function(){var v=document.querySelector('video');return JSON.stringify({paused:v&&v.paused,t:v&&v.currentTime,dropped:v&&v.getVideoPlaybackQuality?v.getVideoPlaybackQuality().droppedVideoFrames:null,total:v&&v.getVideoPlaybackQuality?v.getVideoPlaybackQuality().totalVideoFrames:null})})()")
shot youtube-2 >/dev/null
res youtube "first=$v1 then20s=$v2"
res mem_youtube "$(pss)"
blogs video
res ndl_lines "$(grep -i -E 'ndl|video window|codec' "$B/logs-video.txt" | tail -4 | tr '\n' ' ' | cut -c1-400)"

step brave-shields
# lists: subscriptions are fetched by Brave itself after start; wait until ~3 min since launch 2 have passed
w=$(( 200 - $(dt "$t0" "$(now)" | cut -d. -f1) )); [ $w -gt 0 ] && sleep $w
gsh "find $APPDIR/data $T -name 'engine*.dat' -exec ls -l {} \\; 2>/dev/null; ls -l $APPDIR/data/profile/adblock_cache 2>&1" > "$B/adblock.txt"
res adblock_files "$(tr '\n' ' ' < "$B/adblock.txt" | cut -c1-400)"
cdp nav https://www.bbc.com/ 120 > "$B/nav-bbc2.json"
res bbc_second "$(head -c 300 "$B/nav-bbc2.json")"
shot bbc-2 >/dev/null

step brave-close
blogs final
t=$(now); close > "$B/close-final.txt"
while [ -n "$(procs)" ] && [ "$(dt "$t" "$(now)" | cut -d. -f1)" -lt 60 ]; do sleep 3; done
res close_final "call=$(tr -d '\n' < "$B/close-final.txt" | cut -c1-120) procs_left=[$(procs)] s=$(dt "$t" "$(now)")"
sleep 5; shot after-close >/dev/null
gsh "find $APPDIR/data $T -maxdepth 4 \\( -iname '*crash*' -o -name '*.dmp' \\) 2>/dev/null | head; dmesg | grep -i -E 'segfault|killed|oom' | tail -10" > "$B/crashes.txt"
pkill -f 'ssh .*-L 9222' 2>/dev/null
res brave_result "done"
