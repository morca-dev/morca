#!/bin/sh
# Clones, next to morca, every repository CI's `data` job checks out, at the
# revision it pins there, so the data image builds what CI tests.
#
#     deploy/clone-data-deps.sh <workflow> <dir>
set -eu
workflow=$1
dir=$2
# The `data` job's lines only: up to the next job.
awk '/^  data:/ { on = 1; next } on && /^  [A-Za-z0-9_-]+:/ { exit } on' "$workflow" \
    | grep -o 'repository: [^/,]*/[^,]*, ref: [0-9a-f]*, path: [^,}]*' \
    | sed 's/repository: //; s/, ref: / /; s/, path: / /' \
    | while read -r repo ref path; do
        git clone -q "https://github.com/$repo" "$dir/$path"
        git -C "$dir/$path" checkout -q "$ref"
    done
