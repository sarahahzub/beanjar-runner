#!/bin/bash
# Runs inside a privileged debian:trixie container with /dev/kvm. Inputs (env):
#   FW_ZIP   path of LG's firmware ZIP (downloaded by the workflow at run time, never committed)
#   KERNEL   x86-64 | default   (default: Beanjar's arm64 guest kernel, TCG on an x86_64 host)
#   BOOT_MIN minutes to wait for the TV UI (default 25)
#   OUT      output directory (screenshots, logs, results.txt)
set -u
export DEBIAN_FRONTEND=noninteractive VM_SYSTEMD=0
OUT=${OUT:-/w/out}; BOOT_MIN=${BOOT_MIN:-25}; KERNEL=${KERNEL:-x86-64}; V=0.6.0
mkdir -p "$OUT/shots" "$OUT/logs"
R=$OUT/results.txt; : > "$R"
T0=$(date +%s)
res() { echo "$1=$2" | tee -a "$R"; }
el() { echo $(( $(date +%s) - T0 )); }
step() { echo "== $* (t=$(el)s)"; }

step packages
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends wget ca-certificates git build-essential cmake liblzo2-dev \
	libssl-dev zlib1g-dev unzip python3 python3-pil procps nodejs npm >"$OUT/logs/apt.log" 2>&1 || { tail -20 "$OUT/logs/apt.log"; exit 1; }
arch=$(dpkg --print-architecture)
url=https://github.com/webosbrew/beanjar/releases/download/v$V
mkdir -p /tmp/debs && cd /tmp/debs
pk="beanjar_${V}_$arch.deb beanjar-qemu_${V}_$arch.deb beanjar-ui_${V}_all.deb beanjar-guest_${V}_all.deb beanjar-vnc_${V}_$arch.deb"
[ "$arch" = amd64 ] && pk="$pk beanjar-guest-x86-64_${V}_amd64.deb"
for p in $pk; do wget -q "$url/$p" || { echo "download $p failed"; exit 1; }; done
apt-get install -y -qq $(for p in $pk; do echo ./$p; done) >>"$OUT/logs/apt.log" 2>&1 || { tail -30 "$OUT/logs/apt.log"; exit 1; }
res packages_s "$(el)"

step epk2extract
cd /tmp && git clone -q --depth 1 https://github.com/openlgtv/epk2extract.git && cd epk2extract
CMAKE_FLAGS=-DCMAKE_BUILD_TYPE=Test ./build.sh >"$OUT/logs/epk2extract-build.log" 2>&1 || { tail -20 "$OUT/logs/epk2extract-build.log"; exit 1; }
mkdir -p /opt/epk2extract && cp build_linux/epk2extract build_linux/*.pem build_linux/*.key /opt/epk2extract/
ln -sf /opt/epk2extract/epk2extract /usr/local/bin/epk2extract
res epk2extract_rev "$(git rev-parse --short HEAD)"

step firmware
mkdir -p /fw && cd /fw && unzip -q "$FW_ZIP" && rm -f "$FW_ZIP"
EPK=$(find /fw -iname '*.epk' | head -1)
[ -n "$EPK" ] || { find /fw | head; res result "no epk in zip"; exit 1; }
res epk "$(basename "$EPK")"
res epk_sha256 "$(sha256sum "$EPK" | cut -c1-64)"
res host_cpu "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs) x$(nproc)"
res host_mem_mb "$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
res host_kvm "$([ -c /dev/kvm ] && echo yes || echo no)"
res host_render_node "$(ls /dev/dri/renderD* 2>/dev/null | head -1 || echo none)"

step create
t=$(date +%s)
beanjar create tv1 --firmware "$EPK" --mode direct --layers normal,gl,devmode >"$OUT/logs/create.log" 2>&1
rc=$?; tail -15 "$OUT/logs/create.log"
res create_rc $rc; res create_s $(( $(date +%s) - t ))
if [ $rc != 0 ]; then res result "create refused/failed: $(grep -v '^\s*$' "$OUT/logs/create.log" | tail -2 | tr '\n' ' ' | cut -c1-300)"; exit 0; fi
rm -f "$EPK"
beanjar info tv1 --json > "$OUT/logs/info-created.json" 2>&1
res platform "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("platform") or d.get("target") or "?")' "$OUT/logs/info-created.json" 2>/dev/null)"
if [ "$KERNEL" = x86-64 ]; then beanjar settings tv1 set guest_kernel=x86-64 2>&1 | tail -3; fi
beanjar settings tv1 > "$OUT/logs/settings.txt" 2>&1
VMDIR=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dir"])' "$OUT/logs/info-created.json")

# --- helpers ---
gsh() { timeout 60 beanjar shell tv1 -- sh -c "$1" 2>&1; }
qmp() { # QMP command JSON lines from argv, prints replies
	python3 - "$VMDIR/run/qmp.sock" "$@" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1]); f = s.makefile("rw")
json.loads(f.readline())
for c in ['{"execute":"qmp_capabilities"}'] + sys.argv[2:]:
    f.write(c + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            break
    if "error" in r: print(r)
EOF
}
shot() { # shot NAME : beanjar screenshot, else QMP screendump
	local f="$OUT/shots/$(printf '%04d' "$(el)")-$1.png"
	if timeout 90 beanjar screenshot tv1 "$f" >>"$OUT/logs/screenshot.log" 2>&1 && [ -s "$f" ]; then echo "shot $f"; return; fi
	qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"/tmp/s.ppm\",\"format\":\"ppm\"}}" >>"$OUT/logs/screenshot.log" 2>&1
	python3 -c 'import sys;from PIL import Image;Image.open("/tmp/s.ppm").save(sys.argv[1])' "$f" 2>>"$OUT/logs/screenshot.log" && echo "shot(qmp) $f"
}
fg() { gsh "luna-send -n 1 -f luna://com.webos.applicationManager/getForegroundAppInfo '{}' 2>/dev/null | grep -o '\"appId\": *\"[^\"]*\"' | cut -d'\"' -f4"; }
press() { timeout 30 beanjar remote press tv1 "$@" >>"$OUT/logs/remote.log" 2>&1 || echo "remote press $* failed (rc $?)" | tee -a "$OUT/logs/remote.log"; }
vmstat_line() { ps -C qemu-system-x86_64,qemu-system-aarch64 -o %cpu=,rss= 2>/dev/null | awk '{c+=$1; r+=$2} END {printf "qemu_cpu=%s%% qemu_rss_mb=%d", c, r/1024}'; }

step start
t=$(date +%s)
timeout 600 beanjar start tv1 >"$OUT/logs/start.log" 2>&1; rc=$?
tail -12 "$OUT/logs/start.log"
res start_rc $rc; res start_s $(( $(date +%s) - t ))
grep -i -E 'memory:|userland|kvm|tcg|qemu-user|guest kernel' "$OUT/logs/start.log" | head -8 | sed 's/^/  start: /'
if [ $rc != 0 ]; then res result "start failed"; cp -r "$VMDIR/logs" "$OUT/logs/vm" 2>/dev/null; exit 0; fi

step boot-wait
TS=$(date +%s); booted=""; last_shot=0; n=0
while [ $(( $(date +%s) - TS )) -lt $(( BOOT_MIN * 60 )) ]; do
	sleep 20; n=$((n+1))
	a=$(fg | tail -1)
	echo "t=$(( $(date +%s) - TS ))s fg=[$a] $(vmstat_line) $(beanjar list 2>/dev/null | awk 'NR==2{print $2}')"
	if [ $(( $(date +%s) - last_shot )) -ge 120 ]; then shot boot >/dev/null; last_shot=$(date +%s); fi
	case "$a" in com.*|org.*|*.app.*) booted="$a"; break;; esac
	if ! pgrep -f qemu-system >/dev/null; then echo "QEMU is gone"; break; fi
done
BOOT_S=$(( $(date +%s) - TS ))
res boot_wait_s $BOOT_S; res boot_fg_app "${booted:-none}"
gsh 'cat /etc/starfish-release 2>/dev/null; cat /proc/uptime; cat /proc/loadavg; grep -E "MemTotal|MemAvailable" /proc/meminfo; uname -a' > "$OUT/logs/guest-info.txt"
cat "$OUT/logs/guest-info.txt" | head -8 | sed 's/^/  guest: /'
res qemu_usage "$(vmstat_line)"
shot booted

if [ -n "$booted" ]; then
	sleep 30; shot booted-plus30
	step smoke
	timeout 60 beanjar vnc start tv1 >"$OUT/logs/vnc.log" 2>&1 & sleep 10
	press HOME; sleep 15; shot home; res after_home "$(fg | tail -1)"
	press RIGHT; sleep 4; press RIGHT; sleep 8; shot right2
	press LEFT; sleep 8; shot left1
	t=$(date +%s)
	gsh "luna-send -n 1 luna://com.webos.applicationManager/launch '{\"id\":\"com.palm.app.settings\"}'" > "$OUT/logs/launch-settings.txt"
	sleep 25; shot settings; res settings_fg "$(fg | tail -1)"
	press DOWN; sleep 6; press DOWN; sleep 8; shot settings-down2
	press BACK; sleep 8
	gsh "luna-send -n 1 luna://com.webos.applicationManager/launch '{\"id\":\"com.webos.app.browser\",\"params\":{\"target\":\"about:blank\"}}'" > "$OUT/logs/launch-browser.txt"
	sleep 40; shot browser; res browser_fg "$(fg | tail -1)"
	res browser_procs "$(gsh 'ps -eo comm | grep -c -i -E "wam|webapp|browser|chrom"' | tail -1)"
	# Developer Mode: a tiny web app through the SDK tools
	step devmode-ipk
	(npm install -g --silent @webos-tools/cli >"$OUT/logs/npm.log" 2>&1) && {
		mkdir -p /tmp/app && cd /tmp/app
		echo '{"id":"org.bean.hello","version":"1.0.0","vendor":"bean","type":"web","main":"index.html","title":"Bean Hello"}' > appinfo.json
		echo '<html><body style="background:#2a6;color:#fff;font-size:80px">Hello from Beanjar</body></html>' > index.html
		ares-package -n . -o /tmp >"$OUT/logs/ares.log" 2>&1
		IPK=$(ls /tmp/org.bean.hello_*.ipk 2>/dev/null | head -1)
		timeout 300 beanjar ares-install -d tv1 "$IPK" >>"$OUT/logs/ares.log" 2>&1; res ipk_install_rc $?
		timeout 120 beanjar ares-launch -d tv1 org.bean.hello >>"$OUT/logs/ares.log" 2>&1; res ipk_launch_rc $?
		sleep 30; shot hello-ipk; res hello_fg "$(fg | tail -1)"
		tail -6 "$OUT/logs/ares.log"
	} || res ipk_install "npm install of @webos-tools/cli failed"
fi
res total_s "$(el)"
beanjar vnc stop tv1 >/dev/null 2>&1
timeout 120 beanjar stop tv1 --force >"$OUT/logs/stop.log" 2>&1 || timeout 60 beanjar stop tv1 --force --unplug >>"$OUT/logs/stop.log" 2>&1
cp -r "$VMDIR/logs" "$OUT/logs/vm" 2>/dev/null
res result "${booted:+booted}${booted:-no UI within ${BOOT_MIN} min}"
exit 0
