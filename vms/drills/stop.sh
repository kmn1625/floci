#!/bin/bash
# stop.sh NAME: stop the load and the timeline, print the summary and the timeline's changes.
set -eu
N=$1; D=/root/drills; HERE=$(cd "$(dirname "$0")" && pwd); touch $D/$N.load.stop; sleep 3
python3 "$HERE/summarize.py" $D/$N.load
echo "--- timeline (changes only)"; awk '{l=$0; sub(/^[^ ]+ /,"",l); if (l!=p) print; p=l}' $D/$N.timeline | cut -c1-230
