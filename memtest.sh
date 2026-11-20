# Sourced by run.sh (MODE=memtest) once the TV has booted. Helpers res, step, el, gsh, gshl, shot, fg, press, bootdone
# and VMDIR, OUT, T0 come from run.sh. Installs the Brave IPK (/w/brave.ipk, hash checked by the workflow), does one
# warm-up launch (fresh profile: run.sh seeds the 9 subscriptions, Brave downloads them), then runs configs A-F in
# rounds on the same VM. Per config run: Brave closed, run.sh/browser.flags/Local State set, HTTP+code cache removed,
# page cache dropped, swap emptied; then idle 60 s, BBC, 4 tabs, a <video> page, YouTube once; memory after each.
# Results: $OUT/mem.tsv (one row per config run) and $OUT/logs/mem/*.
now() { date +%s.%N; }
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
LSM=luna://com.webos.applicationManager
ID=com.brave.browser
T=/tmp/$ID
M=$OUT/logs/mem; mkdir -p "$M"
BUDGET_S=$(( ${MEM_BUDGET_MIN:-250} * 60 ))   # no new config run starts after this many seconds since run.sh began
VIDEO=https://upload.wikimedia.org/wikipedia/commons/transcoded/c/c0/Big_Buck_Bunny_4K.webm/Big_Buck_Bunny_4K.webm.720p.vp9.webm
YT="https://www.youtube.com/watch?v=aqz-KE-bpKQ"
SHIPPED_DF=Translate,OptimizationHints,MediaRouter,BackForwardCache,Vulkan,ContextualTasks,ContextualTasksContext,ContextualTasksSidePanel,PreloadTopChromeWebUI,SpareRendererForSitePerProcess,SpareRenderer,OptimizationGuideModelDownloading,IsolateOrigins,site-per-process,WebUIToolbar,WebUIToolbarWebView,WebUIToolbarInternalWebView,WebUIReloadButton,WebUILocationBar,AudioServiceOutOfProcess,WebUIOmniboxPopup,WebUIOmniboxAimPopup,WebUIOmniboxFullPopup,DisableLoadExtensionCommandLineSwitch
EXTRA_DF=AIChat,NativeBraveWallet,Playlist,Speedreader,BraveVPN,BraveRewards

ssh_b() { [ -n "$SSH_ROOT" ] || gsh true >/dev/null; echo "${SSH_ROOT/ssh /ssh -o BatchMode=yes -o ConnectTimeout=10 }"; }
alive() { local i; for i in 1 2; do gsh 'echo ok' | grep -q '^ok' && return 0; sleep 10; done; return 1; }
put() { timeout 120 $(ssh_b) "cat > '$2'" < "$1"; }  # put HOSTFILE GUESTFILE (overwrites in place: owner kept)
helpers() {
	gsh "mkdir -p /tmp/mt" >/dev/null
	for f in snap flags sampler; do put /w/mem/$f.sh /tmp/mt/$f.sh; done
	gsh "kill -0 \$(cat /tmp/mt/sampler.pid 2>/dev/null) 2>/dev/null || { nohup sh /tmp/mt/sampler.sh >/dev/null 2>&1 & echo \$! > /tmp/mt/sampler.pid; }; sleep 6; echo sampler=\$(cat /tmp/mt/sampler.pid) samples=\$(wc -l < /tmp/mt/samples)" | tail -1
}
snap() { gsh "sh /tmp/mt/snap.sh" | tail -1; }
ss_stop() { timeout 60 beanjar screensaver stop tv1 >>"$M/screensaver.log" 2>&1; }
mshot() { ss_stop; shot "$1" >/dev/null; }
mc() { timeout "${2:-400}" python3 /w/memcdp.py $1 2>&1 | tail -1; }
procs() { gsh "for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null | grep -q '[c]om.brave.browser/browser/chrome' && echo \${p#/proc/}; done" | grep -E '^[0-9]+$' | tr '\n' ' '; }
fwd_start() {
	pkill -f 'ssh .*-L 9222' 2>/dev/null; sleep 1
	local f; f=$(ssh_b); f=${f/ssh /ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 9222:127.0.0.1:9222 }
	($f >>"$M/ssh-forward.log" 2>&1 &)
}
brave_close() { # closeByAppId, then kill what is left (root), so the next config starts clean
	local t left; t=$(now)
	gsh "luna-send -n 1 $LSM/closeByAppId '{\"id\":\"$ID\"}'" >/dev/null
	while [ -n "$(procs)" ] && [ "$(dt "$t" "$(now)" | cut -d. -f1)" -lt 45 ]; do sleep 3; done
	left=$(procs); [ -n "$left" ] && { gsh "kill -9 $left"; sleep 5; echo "killed $left"; }
	pkill -f 'ssh .*-L 9222' 2>/dev/null
}
launch_wait() { # launch, wait for a CDP page target; prints seconds or "none"
	local t0 e; t0=$(now)
	gsh "luna-send -n 1 $LSM/launch '{\"id\":\"$ID\"}'" >/dev/null
	sleep 5; fwd_start
	while [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 300 ]; do
		sleep 5; e=$(dt "$t0" "$(now)")
		mc list 20 | grep -q '"page"' && { echo "$e"; return; }
		[ $(( ${e%.*} % 60 )) -lt 5 ] && fwd_start
	done
	echo none
}
recover() { # the guest stopped answering (e.g. out of memory): restart the VM and wait for boot
	echo "$(date +%T) recover at $(el)s: $1" | tee -a "$M/recover.log"
	pkill -f 'ssh .*-L 9222' 2>/dev/null
	timeout 120 beanjar stop tv1 --force >>"$M/recover.log" 2>&1 || timeout 60 beanjar stop tv1 --force --unplug >>"$M/recover.log" 2>&1
	pkill -f beanjar-vnc 2>/dev/null
	timeout 600 beanjar start tv1 >>"$M/recover.log" 2>&1; echo "start rc=$?" >> "$M/recover.log"
	SSH_ROOT=""; local ts; ts=$(date +%s)
	while [ $(( $(date +%s) - ts )) -lt 600 ]; do sleep 20; bootdone | grep -q SIGNAL_boot-done && break; done
	echo "booted after $(( $(date +%s) - ts )) s: $(bootdone | tail -1 | cut -c1-120)" >> "$M/recover.log"
	(timeout 17000 beanjar vnc start tv1 >>"$OUT/logs/vnc.log" 2>&1 &); sleep 15; ss_stop
	helpers >> "$M/recover.log"
	RECOVERS=$((RECOVERS+1))
}
RECOVERS=0

step mem-prep
(timeout 17000 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 &); sleep 15
ss_stop; press HOME; sleep 10
gsh "cat /etc/starfish-release; grep -E 'MemTotal|MemAvailable|SwapTotal' /proc/meminfo; cat /proc/swaps; nproc" > "$M/guest.txt"
res guest_release "$(head -1 "$M/guest.txt")"
res guest_mem "$(grep -E 'MemTotal|SwapTotal' "$M/guest.txt" | tr -s ' ' | tr '\n' ' ')"
res sampler "$(helpers)"

step mem-install
npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1
t=$(now); timeout 900 beanjar ares-install -d tv1 /w/brave.ipk > "$M/ares-install.txt" 2>&1
res install "rc=$? s=$(dt "$t" "$(now)") $(tail -1 "$M/ares-install.txt" | cut -c1-120)"
APPDIR=$(gsh "for d in /media/developer/apps/usr/palm/applications/$ID /media/cryptofs/apps/usr/palm/applications/$ID; do [ -f \$d/appinfo.json ] && echo \$d; done" | grep ^/ | head -1)
res appdir "${APPDIR:-not installed}"
[ -n "$APPDIR" ] || { res mem_result "install failed"; return 0; }
RS=$APPDIR/bin/run.sh
LSF="$APPDIR/data/profile/Local State"
gsh "cp -p $RS $RS.memtest-orig; grep -c 'max-old-space-size=192 --optimize-for-size' $RS" > "$M/runsh.txt"

step mem-warmup
# fresh profile. Also shows what browser.flags does with a two-word --js-flags line (run.sh joins the lines and
# expands them unquoted, so the line is split at the space).
# First a short launch so run.sh creates /tmp/$ID and the data dir as the app's own user.
gsh "luna-send -n 1 $LSM/launch '{\"id\":\"$ID\"}'" > "$M/launch0.txt"; sleep 45
res launch0 "procs=[$(procs)] $(gsh "ls -ld $T $APPDIR/data" | tr '\n' ' ')"
brave_close > /dev/null
gsh "printf '%s\n' --remote-debugging-port=9222 '--js-flags=--max-old-space-size=128 --optimize-for-size' > $T/browser.flags && chmod 644 $T/browser.flags"
res warmup_launch_s "$(launch_wait)"
sleep 20
gsh "sh /tmp/mt/flags.sh" > "$M/warmup-flags.txt"; res warmup_flags "$(grep -E 'browser:|renderer' "$M/warmup-flags.txt" | head -3 | tr '\n' ' ' | cut -c1-600)"
mc "nav first https://www.bbc.com/ 150" > "$M/warmup-bbc1.json"; res warmup_bbc1 "$(cut -c1-300 "$M/warmup-bbc1.json")"
sleep 150  # the subscription lists download in this time (Brave fetches them itself after start)
mc "nav first https://www.bbc.com/ 150" > "$M/warmup-bbc2.json"; res warmup_bbc2 "$(cut -c1-300 "$M/warmup-bbc2.json")"
mshot warmup-bbc
res warmup_mem "$(snap)"
brave_close >/dev/null
gsh "find $APPDIR/data/profile -maxdepth 3 \\( -name 'engine*.dat' -o -iname '*subscription*' \\) -exec ls -ld {} \\; 2>/dev/null | head -20; ls -la $APPDIR/data" > "$M/warmup-files.txt"
timeout 120 $(ssh_b) "exec </dev/null; cat '$LSF'" > "$M/LocalState.warm.json"
python3 - "$M/LocalState.warm.json" > "$M/subs-warm.txt" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("brave", {}).get("ad_block", {}).get("list_subscriptions", {})
for u, v in s.items():
    print(u, {k: v.get(k) for k in ("enabled", "last_successful_update_attempt", "last_update_attempt", "title")})
print("subscriptions:", len(s))
EOF
res warmup_subs "$(tail -1 "$M/subs-warm.txt")"
[ -s "$M/LocalState.warm.json" ] || { res mem_result "no Local State after warm-up"; return 0; }

# config CFG ROUND
lsmode() { case $1 in D|E2|F) echo two;; E) echo none;; *) echo all;; esac; }
jsheap() { case $1 in B) echo 128;; C|F) echo 96;; *) echo 192;; esac; }
cflags() { # browser.flags lines for a config
	echo --remote-debugging-port=9222
	case $1 in
		C) echo --force-gpu-mem-available-mb=64;;
		F) echo --force-gpu-mem-available-mb=64; echo --mse-video-buffer-size-limit-mb=20; echo --mse-audio-buffer-size-limit-mb=3
		   echo "--disable-features=$SHIPPED_DF,$EXTRA_DF";;
	esac
}
row() { printf '%s\n' "$*" | tr ' ' '\t' >> "$OUT/mem.tsv"; }
field() { sed -n "s/.*\"$2\": *\([^,}]*\).*/\1/p" <<<"$1" | head -1 | tr -d '"'; }  # first "key": value in a JSON line
pss_of() { sed -n 's/.*n=\([0-9]*\) pss=\([0-9]*\) swappss=\([0-9]*\).*memavail=\([0-9]*\) swapfree=\([0-9]*\).*/\2 \3 \4 \5/p' <<<"$1"; }
echo "fw cfg round launch_s idle_pss idle_swap bbc_pss bbc_swap tabs_pss tabs_swap video_pss video_swap yt_pss yt_swap memavail_min swapfree_min oom_lines renderer_crash tabs1_unresp/disc tabs2_unresp/disc brave_alive guest_hung bbc_load_ms bbc_blocked bbc2_load_ms bbc2_blocked google_ms wiki_ms guardian_ms video yt" | tr ' ' '\t' > "$OUT/mem.tsv"

runcfg() {
	local C=$1 RND=$2 tag="$1-r$2" t0="" n0="" ls="" j="" s="" idle="" bbc="" bbc_m="" tabs="" vid="" yt="" l="" r1="" r2="" r3="" r4="" tb="" tb1="" vd="" ytv="" mins="" oom="" crash="" alive_b="" hung=N
	step "mem $tag"
	t0=$(date +%s)
	alive || recover "before $tag"
	brave_close > "$M/$tag-close0.txt"
	# run.sh with this config's JS heap (browser.flags cannot carry the two-word --js-flags value, see warm-up)
	gsh "sed 's/--max-old-space-size=192 --optimize-for-size/--max-old-space-size=$(jsheap "$C") --optimize-for-size/' $RS.memtest-orig > $RS; grep -o 'max-old-space-size=[0-9]* --optimize-for-size' $RS" > "$M/$tag-runsh.txt"
	# after a VM restart /tmp/$ID is gone; create it as the app's user, or run.sh cannot write there
	gsh "[ -d $T ] || { mkdir -p $T && chown \$(stat -c %u:%g $APPDIR/data/profile) $T && chmod 700 $T; }"
	cflags "$C" > /tmp/bf; put /tmp/bf "$T/browser.flags"; gsh "chmod 644 $T/browser.flags"
	python3 - "$M/LocalState.warm.json" /tmp/ls.json "$(lsmode "$C")" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); mode = sys.argv[3]
ab = d.setdefault("brave", {}).setdefault("ad_block", {})
s = ab.get("list_subscriptions", {})
if mode == "two":
    s = {u: v for u, v in s.items() if u.endswith("/easylist.txt") or u.endswith("/easyprivacy.txt")}
elif mode == "none":
    s = {}
ab["list_subscriptions"] = s
json.dump(d, open(sys.argv[2], "w"), separators=(",", ":"))
EOF
	put /tmp/ls.json "$LSF"
	ls=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["brave"]["ad_block"]["list_subscriptions"]))' /tmp/ls.json)
	gsh "[ \"\$(md5sum < '$LSF')\" = '$(md5sum < /tmp/ls.json)' ] && echo localstate-ok || echo localstate-DIFFERENT; rm -rf $APPDIR/data/cache/* '$APPDIR/data/profile/Default/Code Cache' $APPDIR/data/profile/Default/GPUCache $APPDIR/data/profile/Default/Cache; sync; echo 3 > /proc/sys/vm/drop_caches; cat /proc/swaps; : > /tmp/mt/samples; dmesg | wc -l" > "$M/$tag-prep.txt"
	ls="$ls,$(head -1 "$M/$tag-prep.txt")"; n0=$(tail -1 "$M/$tag-prep.txt" | tr -dc 0-9)
	l=$(launch_wait)
	gsh "sh /tmp/mt/flags.sh" > "$M/$tag-flags.txt"; res "flags_$tag" "$(grep -E 'browser:|renderer' "$M/$tag-flags.txt" | head -2 | tr '\n' ' ' | cut -c1-500)"
	if [ "$l" = none ]; then hung=$(alive && echo N || echo Y); gsh "tail -c 3000 $T/media.log; tail -c 3000 $T/browser.log; ls -la $T" > "$M/$tag-nolaunch.txt"; fi
	if [ "$l" != none ]; then
		sleep 60; idle=$(snap); echo "idle $idle" >> "$M/$tag-mem.txt"; mshot "$tag-1idle"
		bbc=$(mc "nav first https://www.bbc.com/ 150"); echo "$bbc" > "$M/$tag-bbc.json"
		sleep 10; s=$(snap); echo "bbc $s" >> "$M/$tag-mem.txt"; bbc_m=$s; mshot "$tag-2bbc"
		alive || hung=Y
	fi
	if [ "$l" != none ] && [ $hung = N ]; then
		r1=$(mc "newtab https://www.google.com/ 120"); echo "$r1" > "$M/$tag-google.json"
		r2=$(mc "newtab https://en.wikipedia.org/wiki/Television 120"); echo "$r2" > "$M/$tag-wiki.json"
		r3=$(mc "newtab https://www.theguardian.com/international 150"); echo "$r3" > "$M/$tag-guardian.json"
		sleep 20; tabs=$(snap); echo "tabs $tabs" >> "$M/$tag-mem.txt"; mshot "$tag-3tabs"
		alive || hung=Y
	fi
	if [ "$l" != none ] && [ $hung = N ]; then
		tb1=$(mc tabs 200); echo "$tb1" > "$M/$tag-tabs1.json"
		# BBC again in its own tab, ~4 min after start: Shields lists are loaded by now (blocked count)
		r4=$(mc "nav $(field "$bbc" id) https://www.bbc.com/ 150"); echo "$r4" > "$M/$tag-bbc2.json"
		j=$(field "$r3" id); [ -n "$j" ] || j=first
		vd=$(mc "video $j $VIDEO 60" 300); echo "$vd" > "$M/$tag-video.json"
		vid=$(snap); echo "video $vid" >> "$M/$tag-mem.txt"; mshot "$tag-4video"
		alive || hung=Y
	fi
	if [ "$l" != none ] && [ $hung = N ]; then
		ytv=$(mc "youtube $j $YT 60" 160); echo "$ytv" > "$M/$tag-youtube.json"
		yt=$(snap); echo "youtube $yt" >> "$M/$tag-mem.txt"; mshot "$tag-5youtube"
		tb=$(mc tabs 200); echo "$tb" > "$M/$tag-tabs2.json"
		alive || hung=Y
	fi
	if [ $hung = N ]; then
		mins=$(gsh "awk 'NR==1{a=\$1;f=\$2} \$1<a{a=\$1} \$2<f{f=\$2} END{print a+0, f+0}' /tmp/mt/samples" | tail -1)
		gsh "dmesg | tail -n +$(( ${n0:-0} + 1 )) | grep -i -E 'out of memory|oom|page allocation failure|killed process|lowmem'" > "$M/$tag-dmesg.txt"
		oom=$(grep -c . "$M/$tag-dmesg.txt")
		gsh "grep -i -E 'crash|renderer.*(gone|exit|killed)|oom|out of memory|Aw, Snap|discard' $T/browser.log 2>/dev/null | tail -20" > "$M/$tag-browserlog.txt"
		alive_b=$([ -n "$(procs)" ] && echo Y || echo N)
		cp /dev/null "$M/$tag-close.txt"; brave_close >> "$M/$tag-close.txt"
	else
		mins="? ?"; oom="hung"; alive_b=N
		recover "during $tag"
		gsh "journalctl -k -b -1 --no-pager 2>/dev/null | grep -i -E 'out of memory|oom|page allocation failure' | tail -20" > "$M/$tag-dmesg-prevboot.txt"
	fi
	crash=$(grep -l -E '"crashed": true' "$M"/$tag-*.json 2>/dev/null | wc -l)
	set -- $(pss_of "$idle") ; local ip=${1:-?} is=${2:-?}
	set -- $(pss_of "$bbc_m"); local bp=${1:-?} bs=${2:-?}
	set -- $(pss_of "$tabs") ; local tp=${1:-?} tsw=${2:-?}
	set -- $(pss_of "$vid")  ; local vp=${1:-?} vs=${2:-?}
	set -- $(pss_of "$yt")   ; local yp=${1:-?} ys=${2:-?}
	set -- $mins; local ma=${1:-?} sf=${2:-?}
	local vsum ysum
	vsum=$(sed -n 's/.*"video": *{\([^}]*\)}.*/\1/p' <<<"$vd" | tr -d ' "' | tr ',' ';' | cut -c1-120)
	ysum=$(sed -n 's/.*"video": *{\([^}]*\)}.*/\1/p' <<<"$ytv" | tr -d ' "' | tr ',' ';' | cut -c1-120)
	row "${FWNAME:-fw}" "$C" "$RND" "$l" "$ip" "$is" "$bp" "$bs" "$tp" "$tsw" "$vp" "$vs" "$yp" "$ys" "$ma" "$sf" "$oom" "$crash" \
		"$(field "$tb1" unresponsive)/$(field "$tb1" discarded)" "$(field "$tb" unresponsive)/$(field "$tb" discarded)" "$alive_b" "$hung" "$(field "$bbc" loadEventEnd_ms)" "$(field "$bbc" blocked_by_client)" \
		"$(field "$r4" loadEventEnd_ms)" "$(field "$r4" blocked_by_client)" \
		"$(field "$r1" loadEventEnd_ms)" "$(field "$r2" loadEventEnd_ms)" "$(field "$r3" loadEventEnd_ms)" "${vsum:-none}" "${ysum:-none}"
	res "mem_$tag" "s=$(( $(date +%s) - t0 )) subs=$ls launch=$l idle=[$idle] bbc=[$bbc_m] tabs=[$tabs] video=[$vid] yt=[$yt] min=[$mins] oom=$oom hung=$hung"
}

ORDER1="A F C D B E"; ORDER2="E B D C F A"
for R in 1 2 3; do
	[ $R = 2 ] && O=$ORDER2 || O=$ORDER1
	for C in $O; do
		if [ "$(el)" -gt "$BUDGET_S" ]; then res mem_stopped "time budget reached before $C-r$R at $(el)s"; break 2; fi
		runcfg "$C" "$R"
	done
done
res mem_recovers "$RECOVERS"
gsh "cat $RS.memtest-orig > $RS; rm -f $T/browser.flags" >/dev/null
put "$M/LocalState.warm.json" "$LSF"
cat "$OUT/mem.tsv"
res mem_result "done"
