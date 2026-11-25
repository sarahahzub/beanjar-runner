#!/bin/sh
# Makes the lab's test clips with ffmpeg (all generated, no third-party media). Run in the lab folder: sh gen.sh
# avsync.mp4   720p30 H.264 + AAC, 30 s: a white box for 2 frames and a 1 kHz beep for 67 ms at every full second,
#              with the time and frame number on screen (a camera or a person sees the offset; the page logs timing)
# v1080p60.mp4 1080p60 H.264 High + AAC, 15 s, moving test pattern with a frame counter (60 fps pacing)
# vp9opus.webm 720p30 VP9 + Opus, 15 s
# mse.mp4      fragmented MP4 of avsync (for the MediaSource test, like YouTube)
# tone.m4a / tone.webm  AAC / Opus beeps only
set -e
F=$(fc-match -f '%{file}' 'DejaVu Sans:bold' 2>/dev/null || true)
TXT=""
[ -n "$F" ] && TXT=",drawtext=fontfile=$F:fontsize=64:fontcolor=white:x=40:y=40:text='%{pts\\:hms} f%{frame_num}'"
BEEP="sine=f=1000:r=48000,volume='if(lt(mod(t\,1)\,0.067)\,1\,0)':eval=frame"
ffmpeg -v error -y -f lavfi -i "color=black:s=1280x720:r=30:d=30,drawbox=x=440:y=160:w=400:h=400:color=white:t=fill:enable='lt(mod(t\,1)\,0.067)'$TXT" \
  -f lavfi -t 30 -i "$BEEP" -c:v libx264 -profile:v high -pix_fmt yuv420p -g 30 -b:v 1500k -c:a aac -b:a 128k -ac 2 -shortest avsync.mp4
ffmpeg -v error -y -f lavfi -i "testsrc2=s=1920x1080:r=60:d=15" -f lavfi -t 15 -i "$BEEP" \
  -c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p -g 60 -b:v 8M -c:a aac -b:a 128k -ac 2 -shortest v1080p60.mp4
ffmpeg -v error -y -f lavfi -i "testsrc2=s=1280x720:r=30:d=15" -f lavfi -t 15 -i "$BEEP" \
  -c:v libvpx-vp9 -b:v 1500k -deadline realtime -cpu-used 8 -c:a libopus -b:a 96k -ac 2 -shortest vp9opus.webm
ffmpeg -v error -y -i avsync.mp4 -c copy -movflags frag_keyframe+empty_moov+default_base_moof mse.mp4
ffmpeg -v error -y -f lavfi -t 10 -i "$BEEP" -c:a aac -b:a 128k -ac 2 tone.m4a
ffmpeg -v error -y -f lavfi -t 10 -i "$BEEP" -c:a libopus -b:a 96k -ac 2 tone.webm
ls -l *.mp4 *.webm *.m4a
