#!/bin/bash
# Renders the demo video → mac/promo/usage-pill-demo.mp4  (needs ffmpeg)
#   ./render.sh          full video
#   ./render.sh 5.8      single PNG still at 5.8s (for checking a frame)
set -euo pipefail
cd "$(dirname "$0")"
B=../build; mkdir -p $B
EXTRA=()
[ -f $B/overlay.yaml ] && EXTRA=(-vfsoverlay $B/overlay.yaml -Xcc -ivfsoverlay -Xcc $B/overlay.yaml)
swiftc -O -swift-version 5 ${EXTRA[@]+"${EXTRA[@]}"} -o $B/promo ../UI.swift main.swift -framework AppKit -framework SwiftUI -framework Network -framework ServiceManagement
if [ $# -gt 0 ]; then $B/promo "$1" > "$B/still-$1.png"; echo "$B/still-$1.png"; exit; fi
$B/promo | ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s 1920x1080 -r 60 -i - \
  -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -profile:v high -movflags +faststart usage-pill-demo.mp4
echo "$(pwd)/usage-pill-demo.mp4"
