#!/bin/sh
# Guest side (busybox sh). One line: Brave processes (cmdline has <app>/browser/chrome) by type as
# type=count:PSS_MB:SwapPss_MB, totals, guest MemAvailable/SwapFree. Under qemu-user each is a qemu-arm process.
for p in /proc/[0-9]*; do
	c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null) || continue
	case "$c" in *com.brave.browser/browser/chrome*) ;; *) continue;; esac
	case "$c" in *crashpad*) t=crashpad;; *--type=renderer*) t=renderer;; *--type=gpu-process*) t=gpu;; *--type=utility*) t=utility;; *--type=*) t=other;; *) t=browser;; esac
	awk -v t=$t '/^Pss:/{p=$2} /^SwapPss:/{s=$2} END{if (p!="") print t, p, s+0}' $p/smaps_rollup 2>/dev/null
done | awk '{p[$1]+=$2; s[$1]+=$3; n[$1]++; P+=$2; S+=$3; N++} END{printf "n=%d pss=%d swappss=%d", N, P/1024, S/1024; for (k in p) printf " %s=%d:%d:%d", k, n[k], p[k]/1024, s[k]/1024}'
awk '/MemAvailable/{a=int($2/1024)} /SwapFree/{f=int($2/1024)} /SwapTotal/{t=int($2/1024)} END{printf " memavail=%d swapfree=%d swaptotal=%d\n", a, f, t}' /proc/meminfo
