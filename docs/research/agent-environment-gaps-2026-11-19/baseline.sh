#!/bin/bash
# baseline.sh <agent image> <postgres snapshot image or -> <mix test args...>
# Runs tests on an untouched case image the way the harness sandbox starts it. Read-only check; containers are removed.
img=$1; pg=$2; shift 2; name=eabprobe-$RANDOM; net=none
cleanup() { docker rm -f -v $name $name-db >/dev/null 2>&1; }; trap cleanup EXIT
if [ "$pg" != "-" ]; then
  docker run -d --name $name-db --network=none --memory=1g --cpus=1 -e POSTGRES_PASSWORD=postgres $pg >/dev/null || exit 1
  docker exec $name-db sh -c 'for i in $(seq 1 60); do pg_isready -h 127.0.0.1 -U postgres >/dev/null && exit 0; sleep 1; done; exit 1' || { echo "db not ready"; exit 1; }
  net=container:$name-db
fi
docker run -d --name $name --init --network=$net --cap-drop=ALL --security-opt=no-new-privileges --memory=4g --cpus=2 --pids-limit=512 --tmpfs=/tmp:rw,nosuid,size=512m $img >/dev/null || exit 1
docker exec -w /workspace $name timeout -k 5 900 bash -lc "mkdir -p /tmp/eab-certs; mix test $* 2>&1" | grep -E "^\s+[0-9]+\) test|\*\* \(|tests?, [0-9]+ failures|oEmbed|no such file|Assertion|left:|right:|nxdomain|econnrefused|Permission denied|no matching message" | cut -c1-200 | head -40
