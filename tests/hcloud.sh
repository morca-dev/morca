#!/bin/sh
# morca.hcloud (the pool autoscaler's Hetzner client, #267) against
# tests/fake_hcloud.py: types, firewalls, create with and without stock,
# list by label over pages, delete, a server's user data run, and errors that
# keep the token out.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
one_cluster_test
mkdir -p build
dir=$PWD/build/hcloud
rm -rf "$dir"
mkdir -p "$dir"
free_port port
python3 tests/fake_hcloud.py "$port" "$dir" &
fake=$!
trap 'kill $fake 2> /dev/null || true' EXIT
export MORCA_HCLOUD_ENDPOINT="http://127.0.0.1:$port/v1" MORCA_HCLOUD_TOKEN=test-token HCLOUD_DIR="$dir"
unset AWS_REGION AWS_DEFAULT_REGION
i=0
until curl -s -o /dev/null "$MORCA_HCLOUD_ENDPOINT/server_types"; do
    i=$((i + 1)); [ "$i" -lt 100 ] || { echo "FAIL: the fake didn't start"; exit 1; }
    sleep 0.1
done
# tests/test_hcloud.mojo, from the executor-workers shard's binary.
scripts/unit-tests.sh build executor-workers
scripts/unit-tests.sh run test-hcloud
echo "hcloud: ok"
