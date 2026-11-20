# Sourced by run.sh (MODE=bench) after `beanjar create`: helpers res, step, gsh, gsh_in, shot, fg, press,
# vmstat_line and VMDIR, OUT come from run.sh. Three boots, then CPU, web runtime and app launch timings.
now() { date +%s.%N; }
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
LS=luna://com.webos.applicationManager

for i in 1 2 3; do
	step "boot $i"
	t0=$(now)
	timeout 600 beanjar start tv1 > "$OUT/logs/start-$i.log" 2>&1 || { res boot$i "start failed"; tail -5 "$OUT/logs/start-$i.log"; break; }
	t1=$(now); luna_s=""; bd_s=""; home_s=""
	while [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 300 ]; do
		el=$(dt "$t0" "$(now)")
		o=$(gsh "luna-send -n 1 luna://com.webos.service.bootmanager/getBootStatus '{}'; echo; luna-send -n 1 $LS/getForegroundAppInfo '{}'")
		[ -z "$luna_s" ] && echo "$o" | grep -q returnValue && luna_s=$el
		[ -z "$bd_s" ] && echo "$o" | grep -q '"boot-done": *true' && bd_s=$el
		[ -z "$home_s" ] && echo "$o" | grep -q '"appId": *"com.webos.app.home"' && home_s=$el
		[ -n "$home_s" ] && break
		sleep 1
	done
	up=$(gsh "grep -h SIGNAL_boot-done /var/log/bootd.log | tail -1 | grep -o '[0-9.]*' | head -1")
	res boot$i "start_cmd_s=$(dt "$t0" "$t1") luna_up_s=${luna_s:-none} boot_done_s=${bd_s:-none} home_fg_s=${home_s:-none} bootd_uptime=${up:-?} $(vmstat_line)"
	shot "boot$i-home" >/dev/null
	if [ $i -lt 3 ]; then
		t=$(now); timeout 240 beanjar stop tv1 --force > "$OUT/logs/stop-$i.log" 2>&1; res stop${i} "rc=$? s=$(dt "$t" "$(now)")"
	fi
done

step settle
sleep 30
(timeout 3000 beanjar vnc start tv1 > "$OUT/logs/vnc.log" 2>&1 &); sleep 10
timeout 90 beanjar screensaver stop tv1 --json > "$OUT/logs/screensaver-stop.json" 2>&1
res guest "$(gsh 'uname -m; uname -r; grep -c ^processor /proc/cpuinfo; grep MemTotal /proc/meminfo' | tr '\n' ' ')"

step cpu
gsh_in "cat > /tmp/cpubench.sh" < /w/cpubench.sh
timeout 300 ${SSH_ROOT/ssh /ssh -o BatchMode=yes } "exec </dev/null; sh /tmp/cpubench.sh" 2>&1 </dev/null | tee "$OUT/logs/cpubench.txt"
res cpu_qemu_during "$(vmstat_line)"

step apps
mkdir -p /tmp/ipk/app && cd /tmp/ipk/app
echo '{"id":"org.bean.bench","version":"1.0.0","vendor":"bean","type":"web","main":"index.html","title":"Bean Bench","icon":"icon.png"}' > appinfo.json
cp /w/bench.html index.html
python3 -c 'from PIL import Image; Image.new("RGB",(80,80),(40,160,90)).save("icon.png")'
python3 /w/mkipk.py /tmp/ipk/app /tmp/ipk/org.bean.bench_1.0.0_all.ipk
gsh_in "cat > /tmp/bench.ipk" < /tmp/ipk/org.bean.bench_1.0.0_all.ipk
gsh "mkdir -p /tmp/bench" >/dev/null; gsh_in "cat > /tmp/bench/index.html" < /w/bench.html; gsh_in "cat > /tmp/bw.py" < /w/bw.py
gsh "luna-send -n 6 luna://com.webos.appInstallService/dev/install '{\"id\":\"org.bean.bench\",\"ipkUrl\":\"/tmp/bench.ipk\",\"subscribe\":true}'" > "$OUT/logs/ipk-install.txt"
sleep 5; tail -c 600 "$OUT/logs/ipk-install.txt"; echo
res ipk_installed "$(gsh 'ls /media/developer/apps/usr/palm/applications/ 2>/dev/null | tr "\n" " "')"

for app in com.palm.app.settings com.webos.app.home; do
	for i in 1 2 3; do
		[ $app = com.palm.app.settings ] && gsh "luna-send -n 1 $LS/closeByAppId '{\"id\":\"$app\"}'" >/dev/null && sleep 5
		[ $app = com.webos.app.home ] && gsh "luna-send -n 1 $LS/launch '{\"id\":\"com.palm.app.settings\"}'" >/dev/null && sleep 20
		t0=$(now); gsh "luna-send -n 1 $LS/launch '{\"id\":\"$app\"}'" > "$OUT/logs/launch-$app-$i.txt"; t1=$(now)
		while [ "$(fg | tail -1)" != "$app" ] && [ "$(dt "$t0" "$(now)" | cut -d. -f1)" -lt 90 ]; do sleep 0.3; done
		res "launch_${app}_$i" "call_s=$(dt "$t0" "$t1") fg_s=$(dt "$t0" "$(now)")"
		[ $i = 1 ] && shot "$app" >/dev/null
	done
done
press DOWN; sleep 3; shot dpad-down >/dev/null

step web
gshl "timeout 400 python3 /tmp/bw.py org.bean.bench 2" | tee "$OUT/logs/bw-webapp.txt"
shot webapp >/dev/null
gshl "timeout 400 python3 /tmp/bw.py com.webos.app.browser 2 http://127.0.0.1:8099/" | tee "$OUT/logs/bw-browser.txt"
shot browser >/dev/null
res web_qemu "$(vmstat_line)"
res total_s "$(el)"
timeout 120 beanjar stop tv1 --force > "$OUT/logs/stop-final.log" 2>&1
cp -r "$VMDIR/logs" "$OUT/logs/vm" 2>/dev/null
