# TV-side CPU micro-benchmarks with the TV's own 32-bit binaries; run with the TV's /bin/sh. 3 rounds.
up() { cut -d' ' -f1 /proc/uptime; }
d() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
echo "bins: sh=$(readlink -f /bin/sh) md5sum=$(readlink -f "$(command -v md5sum)") openssl=$(command -v openssl)"
for n in 1 2 3; do
	a=$(up); sh -c 'i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done'; b=$(up); L=$(d $a $b)
	a=$(up); dd if=/dev/zero bs=1M count=100 2>/dev/null | md5sum >/dev/null; b=$(up); M=$(d $a $b)
	S=$(openssl speed -seconds 3 sha256 2>/dev/null | awk '/^sha256/{print $NF}')
	echo "round=$n loop200k_s=$L md5_100MB_s=$M sha256_16k=$S"
done
