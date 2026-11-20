#!/bin/sh
# Guest side: MemAvailable and SwapFree (MB) every 5 s into /tmp/mt/samples (memtest.sh truncates it per config).
while :; do
	awk '/MemAvailable/{a=int($2/1024)} /SwapFree/{f=int($2/1024)} END{print a, f}' /proc/meminfo >> /tmp/mt/samples
	sleep 5
done
