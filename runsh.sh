# Sourced by run.sh (MODE=runsh) once the TV has booted. Tests Brave's run.sh from 1.99.5853 (Chromium Beta 0.0.66's
# run.sh + Brave's additions): (a) normal launch, window + page, (b) launcher GPU-off path (media.opts gpu=off ->
# CN_GPU=off -> --disable-gpu), (c) <app>/data/lastlog after exit, (d) hw.json on webOS 4 (NDL API 1), plus
# browser.flags lines with spaces staying one argument, a SIGSEGV of the browser process (what lastlog keeps) and
# whether the Developer Mode user can read lastlog. Helpers res, step, el, gsh, gshl, shot, fg, press come from run.sh.
now() { date +%s.%N; }
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
LS=luna://com.webos.applicationManager
ID=com.brave.browser
T=/tmp/$ID
B=$OUT/logs/brave; mkdir -p "$B"
gsh true >/dev/null
SSHB=${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ConnectTimeout=10 }
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[c]om.brave.browser/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
mainpid() { gsh "for p in /proc/[0-9]*; do c=\$(tr '\\0' ' ' < \$p/cmdline 2>/dev/null); case \"\$c\" in *com.brave.browser/browser/chrome*--class=*) case \"\$c\" in *--type=*) ;; *) echo \${p#/proc/};; esac;; esac; done" | grep -E '^[0-9]+$' | head -1; }
args() { # args TAG: the browser process's arguments, one per line
	local p; p=$(mainpid); [ -n "$p" ] || { echo "no browser process" > "$B/args-$1.txt"; return; }
	gsh "tr '\\0' '\\n' < /proc/$p/cmdline" > "$B/args-$1.txt"; }
blogs() { gsh "cd $T 2>/dev/null && for f in media.log browser.log start-check.log media.opts browser.flags hw.state mem.txt; do [ -f \$f ] && { echo \"==== \$f\"; tail -c 60000 \$f; }; done" > "$B/logs-$1.txt"; }
launch() { gsh "luna-send -n 1 $LS/launch '$1'"; }
close() { gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$ID\"}'"; }
cdp() { timeout 300 python3 /w/cdp.py "$@" 2>&1 | tail -1; }
waitwin() { # waitwin TAG: poll up to 240 s (screenshots), returns when a CDP page target exists or no process after 120 s
	local t0 e p; t0=$(now); WIN_S=""
	while [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 240 ]; do
		sleep 10; e=$(dt "$t0" "$(now)"); p=$(procs)
		echo "t=$e procs=[$p] fg=[$(fg | tail -1)]" >> "$B/poll-$1.txt"
		[ $(( ${e%.*} % 30 )) -lt 10 ] && shot "$1-$(printf %03d "${e%.*}")s" >/dev/null
		if [ -n "$CDP" ] && timeout 15 python3 /w/cdp.py list > /tmp/l.json 2>&1 && grep -q '"page"' /tmp/l.json; then WIN_S=$e; break; fi
		[ -z "$CDP" ] && [ -n "$p" ] && [ "${e%.*}" -ge 90 ] && { WIN_S=$e; break; }
		[ -z "$p" ] && [ "${e%.*}" -gt 120 ] && break
	done; }
waitgone() { local t; t=$(now); while [ -n "$(procs)" ] && [ "$(dt "$t" "$(now)" | cut -d. -f1)" -lt 60 ]; do sleep 3; done; echo "procs_left=[$(procs)] s=$(dt "$t" "$(now)")"; }
lastlog() { # lastlog TAG: what is in <app>/data/lastlog and lastlog.prev
	gsh "for d in $APPDIR/data/lastlog $APPDIR/data/lastlog.prev; do echo \"#### \$d\"; ls -la \$d 2>&1; for f in \$d/*; do [ -f \$f ] && { echo \"== \$f (\$(wc -l < \$f) lines)\"; tail -n 6 \$f | cut -c1-300; }; done; done" > "$B/lastlog-$1.txt"; }
own() { gsh "chown $AU $1 && chmod 644 $1; ls -l $1"; }

step runsh-prep
(timeout 6000 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1; res screensaver_stop_rc $?
press HOME; sleep 10; shot home >/dev/null
gsh "cat /etc/starfish-release; grep -E 'MemTotal|MemAvailable' /proc/meminfo" > "$B/guest.txt"; res guest_release "$(head -1 "$B/guest.txt")"

step runsh-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$B/ares-install.txt" 2>&1; res install_ares "rc=$? $(tail -1 "$B/ares-install.txt" | cut -c1-200)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
if [ -z "$APPDIR" ]; then
	gsh "mkdir -p /media/developer/temp" >/dev/null
	timeout 900 $SSHB "exec cat > /media/developer/temp/brave.ipk" < /w/brave.ipk
	gshl "luna-send -n 30 -w 600000 luna://com.webos.appInstallService/dev/install '{\"id\":\"$ID\",\"ipkUrl\":\"/media/developer/temp/brave.ipk\",\"subscribe\":true}'" > "$B/dev-install.txt"
	APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
	gsh "rm -f /media/developer/temp/brave.ipk" >/dev/null
fi
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res runsh_result "install failed"; return 0; }
res app_version "$(gsh "grep version $APPDIR/appinfo.json" | tr -d '\n ')"
res runsh_sha "$(gsh "sha256sum $APPDIR/bin/run.sh" | cut -c1-64)"

if [ -f /w/run.sh.fix ]; then # quick lastlog check of a fixed run.sh on top of the installed package
	step fix-install
	timeout 60 $SSHB "exec cat > $APPDIR/bin/run.sh" < /w/run.sh.fix
	gsh "chmod 755 $APPDIR/bin/run.sh" >/dev/null
	res fix_sha "want=$(sha256sum /w/run.sh.fix | cut -c1-64) got=$(gsh "sha256sum $APPDIR/bin/run.sh" | cut -c1-64)"
	step fix-launch1
	CDP=""; launch "{\"id\":\"$ID\"}" > "$B/launch-f1.txt"; waitwin f1
	res f1_window "s=$WIN_S procs=[$(procs)] fg=[$(fg | tail -1)]"; shot f1-window >/dev/null
	sleep 30; lastlog f1-running
	res f1_lastlog_running "$(grep -E '^-' "$B/lastlog-f1-running.txt" | awk '{print $5, $NF}' | tr '\n' ';')"
	close > /dev/null; res f1_close "$(waitgone)"; sleep 10
	lastlog f1-closed
	res f1_lastlog_closed "$(grep -E '^-' "$B/lastlog-f1-closed.txt" | awk '{print $5, $NF}' | tr '\n' ';')"
	res f1_mem_tail "$(grep -A6 'lastlog/mem.txt' "$B/lastlog-f1-closed.txt" | tail -3 | tr '\n' ' ' | cut -c1-300)"
	res f1_helpers_left "$(gsh "ps -ef 2>/dev/null | grep -c '[r]un.sh'")"
	step fix-launch2-segv
	launch "{\"id\":\"$ID\"}" > "$B/launch-f2.txt"; waitwin f2
	res f2_window "s=$WIN_S procs=[$(procs)]"
	lastlog f2-running
	res f2_lastlog_prev "$(sed -n '/lastlog.prev$/,$p' "$B/lastlog-f2-running.txt" | grep -E '^-' | awk '{print $5, $NF}' | tr '\n' ';')"
	P=$(mainpid); gsh "kill -SEGV $P" >/dev/null; res f2_segv "pid=$P $(waitgone)"
	sleep 30; lastlog f2-segv
	res f2_lastlog_segv "$(grep -E '^-' "$B/lastlog-f2-segv.txt" | awk '{print $5, $7, $8, $NF}' | tr '\n' ';')"
	res f2_media_tail "$(grep -A6 'lastlog/media.log' "$B/lastlog-f2-segv.txt" | tail -2 | tr '\n' ' ' | cut -c1-300)"
	res f2_mem_tail "$(grep -A6 'lastlog/mem.txt' "$B/lastlog-f2-segv.txt" | tail -2 | tr '\n' ' ' | cut -c1-300)"
	res runsh_result "fix done"
	return 0
fi

step a-launch-plain
CDP=""
t0=$(now); launch "{\"id\":\"$ID\"}" > "$B/launch-a.txt"
waitwin a
res a_window "s=$WIN_S procs=[$(procs)] fg=[$(fg | tail -1)]"
sleep 30; shot a-window >/dev/null
args a; blogs a
res a_disable_gpu "$(grep -c -x -- --disable-gpu "$B/args-a.txt") (want 0)"
res a_gpu_line "$(grep -m1 'gpu:' "$B/logs-a.txt" | cut -c1-200)"
res a_ndl_line "$(grep -m1 'ndl api' "$B/logs-a.txt" | cut -c1-200)"
res a_flags "isolate=$(grep -c -x -- --isolate-origins=https://challenges.cloudflare.com "$B/args-a.txt") skip_origin=$(grep -c -x -- --skip-origin-startup-dialog "$B/args-a.txt") window=$(grep -x -- '--window-size=.*' "$B/args-a.txt") component_update_off=$(grep -c -x -- --disable-component-update "$B/args-a.txt") bg_net_off=$(grep -c -x -- --disable-background-networking "$B/args-a.txt") features=$(grep -- '--disable-features=' "$B/args-a.txt" | grep -o 'HardwareMediaKeyHandling,NetworkTimeServiceQuerying,WebGPUService,WebGPUBlobCache')"
AU=$(gsh "stat -c %u:%g $T" | tail -1); res app_user "$AU"
step d-hwjson
gsh "cat $APPDIR/data/ext/tvtools/hw.json; ls -l $APPDIR/data/ext/tvtools/hw.json; cat $APPDIR/data/ext/.version; grep '\"version\"' $APPDIR/data/ext/tvtools/manifest.json; cat $T/hw.state 2>&1" > "$B/hwjson-a.txt"
res d_hwjson "$(tr '\n' ' ' < "$B/hwjson-a.txt" | cut -c1-400)"

step c-lastlog-close
close > "$B/close-a.txt"; res a_close "$(waitgone)"
sleep 75   # the lastlog writer checks once a minute whether Chrome still runs, then saves
lastlog a-closed; res c_lastlog_after_close "$(grep -E '^(-|d)' "$B/lastlog-a-closed.txt" | awk '{print $1, $5, $NF}' | tr '\n' ';' | cut -c1-400)"
res c_mem_tail "$(grep -A6 'lastlog/mem.txt' "$B/lastlog-a-closed.txt" | tail -2 | tr '\n' ' ' | cut -c1-200)"
res c_running_helpers "$(gsh "ps -ef 2>/dev/null | grep -c '[r]un.sh'")"

step a2-launch-cdp
gsh "printf '%s\n' '--remote-debugging-port=9222' '# comment line' '  --js-flags=--max-old-space-size=160 --optimize-for-size  ' '' > $T/browser.flags" >/dev/null; own $T/browser.flags > "$B/flags.txt"
CDP=1
FWD=${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 }
launch "{\"id\":\"$ID\"}" > "$B/launch-a2.txt"; sleep 5
($FWD >"$B/ssh-forward.log" 2>&1 &)
waitwin a2
res a2_cdp_page "s=${WIN_S:-none} $(head -c 200 /tmp/l.json)"
args a2
res a2_jsflags_one_arg "$(grep -n -- '--js-flags=' "$B/args-a2.txt" | tr '\n' ' ')"
res a2_remote_debug_arg "$(grep -c -x -- --remote-debugging-port=9222 "$B/args-a2.txt")"
cdp gpu > "$B/gpu-a2.json"; res a2_gpu "$(head -c 400 "$B/gpu-a2.json")"
cdp nav https://en.wikipedia.org/wiki/Television 150 > "$B/nav-a2.json"; res a2_wikipedia "$(head -c 300 "$B/nav-a2.json")"
sleep 10; shot a2-wikipedia >/dev/null
res a2_lastlog_prev "$(gsh "ls $APPDIR/data/lastlog.prev $APPDIR/data/lastlog 2>&1" | tr '\n' ' ')"
# a no-SSH way to read lastlog: open it in Brave itself
cdp nav "file://$APPDIR/data/lastlog.prev/media.log" 30 > "$B/nav-filelog.json"
res file_url_lastlog "$(cdp eval "((document.body||{}).innerText||'').split('\n').slice(-3).join(' | ')" | cut -c1-300)"
sleep 5; shot file-url-lastlog >/dev/null
close > /dev/null; res a2_close "$(waitgone)"
pkill -f 'ssh .*-L 9222' 2>/dev/null

step b-gpu-off
gsh "echo gpu=off > $T/media.opts" >/dev/null; own $T/media.opts >> "$B/flags.txt"
launch "{\"id\":\"$ID\"}" > "$B/launch-b.txt"; sleep 5
($FWD >"$B/ssh-forward-b.log" 2>&1 &)
waitwin b
res b_window "s=${WIN_S:-none} procs=[$(procs)] fg=[$(fg | tail -1)]"
args b; blogs b
res b_disable_gpu "$(grep -c -x -- --disable-gpu "$B/args-b.txt") (want 1)"
res b_gpu_line "$(grep 'gpu:' "$B/logs-b.txt" | tail -1 | cut -c1-200)"
cdp gpu > "$B/gpu-b.json"; res b_gpu_cdp "$(head -c 400 "$B/gpu-b.json")"
cdp nav https://en.wikipedia.org/wiki/Television 150 > "$B/nav-b.json"; res b_wikipedia "$(head -c 300 "$B/nav-b.json")"
sleep 10; shot b-wikipedia >/dev/null

step e-segv
P=$(mainpid); res e_main_pid "$P"
t=$(now); gsh "kill -SEGV $P" >/dev/null
res e_after "$(waitgone)"
sleep 75
blogs e
res e_launcher_lines "$(grep -E 'chrome exited|gpu: Chrome ended' "$B/logs-e.txt" | tail -2 | tr '\n' ' ' | cut -c1-300)"
lastlog e-segv
res e_lastlog "$(grep -E '^(-|d)' "$B/lastlog-e-segv.txt" | awk '{print $1, $5, $6, $7, $8, $NF}' | tr '\n' ';' | cut -c1-500)"
res e_browserlog_tail "$(grep -A6 'lastlog/browser.log' "$B/lastlog-e-segv.txt" | tail -4 | tr '\n' ' ' | cut -c1-400)"
res e_media_tail "$(grep -A6 'lastlog/media.log' "$B/lastlog-e-segv.txt" | tail -3 | tr '\n' ' ' | cut -c1-400)"
gsh "find $APPDIR/data $T -maxdepth 5 \\( -iname '*crash*' -o -name '*.dmp' -o -name 'core*' \\) 2>/dev/null | head; dmesg | grep -i -E 'segfault|signal 11' | tail -3" > "$B/crash-files.txt"
res e_crash_files "$(tr '\n' ' ' < "$B/crash-files.txt" | cut -c1-300)"
pkill -f 'ssh .*-L 9222' 2>/dev/null

step devmode-read
gsh "id prisoner 2>&1; for d in /media/developer /media/developer/apps /media/developer/apps/usr /media/developer/apps/usr/palm /media/developer/apps/usr/palm/applications $APPDIR $APPDIR/data $APPDIR/data/lastlog; do ls -ld \$d; done; ls -l $APPDIR/data/lastlog; su -s /bin/sh prisoner -c 'head -c 120 $APPDIR/data/lastlog/media.log' 2>&1 | head -3" > "$B/devmode-read.txt"
res devmode_read "$(tr '\n' ';' < "$B/devmode-read.txt" | cut -c1-900)"
gsh "rm -f $T/media.opts $T/browser.flags" >/dev/null
res runsh_result "done"
