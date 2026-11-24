#!/bin/sh
# memsnap.sh TAG: one line of free memory, then every process over 20 MB resident (KB, command), biggest first.
# Run in the guest (launch.sh, launch-mem step).
echo "$1 $(grep -E 'MemAvailable|SwapFree' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"
for p in /proc/[0-9]*; do
	r=$(awk '/^VmRSS/{print $2}' "$p/status" 2>/dev/null)
	[ -n "$r" ] && [ "$r" -gt 20000 ] && echo "  $r $(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-90)"
done | sort -rn | head -n 14
