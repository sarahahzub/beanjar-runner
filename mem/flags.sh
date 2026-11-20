#!/bin/sh
# Guest side. For each Brave process: its type and the memory switches on its command line, in order
# (shows whether a browser.flags value follows run.sh's value, and what the renderer actually received).
for p in /proc/[0-9]*; do
	c=$(tr '\0' '\n' < $p/cmdline 2>/dev/null) || continue
	case "$c" in *com.brave.browser/browser/chrome*) ;; *) continue;; esac
	t=$(echo "$c" | grep -m1 '^--type=' || echo browser)
	f=$(echo "$c" | grep -E '^--(js-flags|force-gpu-mem-available-mb|mse-video-buffer-size-limit-mb|mse-audio-buffer-size-limit-mb|optimize-for-size|max-old-space-size)' | tr '\n' '|')
	d=$(echo "$c" | grep -c '^--disable-features')
	l=$(echo "$c" | grep '^--disable-features' | tail -1 | tr ',' '\n' | grep -c -E '^(AIChat|NativeBraveWallet|Playlist|Speedreader|BraveVPN|BraveRewards)$')
	echo "${p#/proc/} $t: $f disable-features x$d (last one has $l of the extra Brave names)"
done
