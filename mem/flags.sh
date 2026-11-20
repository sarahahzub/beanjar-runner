#!/bin/sh
# Guest side. For each Brave process: its type and the memory switches on its command line, in order
# (shows whether a browser.flags value follows run.sh's value, and what the renderer actually received).
# Chrome's children rewrite their cmdline into one space-joined string (process title), so match with grep -o.
for p in /proc/[0-9]*; do
	c=$(tr '\0' '\n' < $p/cmdline 2>/dev/null) || continue
	case "$c" in *com.brave.browser/browser/chrome*) ;; *) continue;; esac
	t=$(echo "$c" | tr '\n' ' ' | grep -o -m1 -- '--type=[a-z-]*' || echo browser)
	case "$c" in *chrome_crashpad_handler*) t=crashpad;; esac
	f=$(echo "$c" | tr '\n' ' ' | grep -o -E -- '--(js-flags=--max-old-space-size=[0-9]+( --optimize-for-size)?|force-gpu-mem-available-mb=[0-9]+|mse-video-buffer-size-limit-mb=[0-9]+|mse-audio-buffer-size-limit-mb=[0-9]+|optimize-for-size)' | tr '\n' '|')
	d=$(echo "$c" | tr '\n' ' ' | grep -o -- '--disable-features=[^ ]*' | wc -l)
	l=$(echo "$c" | tr '\n' ' ' | grep -o -- '--disable-features=[^ ]*' | tail -1 | tr ',=' '\n\n' | grep -c -E '^(AIChat|NativeBraveWallet|Playlist|Speedreader|BraveVPN|BraveRewards)$')
	echo "${p#/proc/} $t: $f disable-features x$d (last one has $l of the extra Brave names)"
done
