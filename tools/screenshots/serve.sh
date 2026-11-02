#!/bin/zsh
# serve.sh <live dir> [port]: serves the demo Live TV source (demo/live.py) and loops each channel clip as live HLS.
D=${1:A}; PORT=${2:-8765}
pids=()
for clip in $D/clip-*.mp4; do
  n=${${clip:t:r}#clip-}; mkdir -p $D/live-$n; rm -f $D/live-$n/*(N)
  ffmpeg -nostdin -loglevel error -re -stream_loop -1 -i $clip -c copy -f hls -hls_time 2 -hls_list_size 6 \
    -hls_flags delete_segments+omit_endlist $D/live-$n/index.m3u8 & pids+=($!)
done
python3 -m http.server $PORT -d $D >/dev/null 2>&1 & pids+=($!)
trap "kill $pids 2>/dev/null" EXIT INT TERM
wait
