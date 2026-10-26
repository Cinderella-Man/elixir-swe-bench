#!/usr/bin/env bash
# Usage: hidden-check.sh <case> <label> <solution.patch|-> <acceptance.patch> [test command...]
# Mirrors the grader's hidden stage in throwaway containers: apply the solution,
# restore test/ to the baseline, apply the hidden tests, run the acceptance command.
# Prepared PostgreSQL/ClickHouse images run beside the workspace in one network namespace.
set -euo pipefail
case_id=$1 label=$2 solution=$3 acceptance=$4
shift 4
S=${EAB_RUNTIME_DIR:?set EAB_RUNTIME_DIR to a folder holding runtime-<case>.json records}
runtime=$S/runtime-$case_id.json
field() { python3 -I -c "import json,sys;r=json.load(open(sys.argv[1]));v=r$1;print(v if v is not None else '')" "$runtime"; }
image=$(field "['image']")
postgres=$(field ".get('services',{}).get('postgres')")
clickhouse=$(field ".get('services',{}).get('clickhouse')")
envs=$(python3 -I -c "import json,sys;e=json.load(open(sys.argv[1]))['database_inputs']['environment'];print(' '.join('-e %s=%s'%(k,v.replace(' ','\\\\ ')) for k,v in e.items()))" "$runtime")
command=${*:-$(python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))['grading']['acceptance'])" "${EAB_DRAFTS_DIR:?set EAB_DRAFTS_DIR}/$case_id/case.json")}
name=hidden-check-$RANDOM
network=none
cleanup() { docker rm -f -v $name $name-db $name-ch >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [ -n "$postgres" ]; then
  docker run -d --name $name-db --network=none --memory=512m --cpus=1 -e POSTGRES_PASSWORD=postgres "$postgres" >/dev/null
  docker exec $name-db sh -c 'for i in $(seq 1 60); do pg_isready -h 127.0.0.1 -U postgres >/dev/null && exit 0; sleep 1; done; exit 1'
  network=container:$name-db
fi
if [ -n "$clickhouse" ]; then
  docker run -d --name $name-ch --network=$network --memory=3g --cpus=2 --ulimit nofile=262144:262144 \
    -e CLICKHOUSE_SKIP_USER_SETUP=1 "$clickhouse" >/dev/null
  docker exec $name-ch sh -c "for i in \$(seq 1 90); do clickhouse-client --query 'SELECT 1' >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"
fi
eval docker run -d --name $name --init --network=$network --cap-drop=ALL --security-opt=no-new-privileges \
  --memory=4g --cpus=2 --pids-limit=512 --tmpfs=/tmp:rw,nosuid,size=512m $envs "$image" >/dev/null
if [ "$solution" != "-" ]; then
  docker exec -i $name sh -c 'cat > /tmp/solution.patch' < "$solution"
  docker exec -w /workspace $name git apply --whitespace=nowarn /tmp/solution.patch
fi
docker exec -i $name sh -c 'cat > /tmp/acceptance.patch' < "$acceptance"
docker exec -w /workspace $name sh -c 'git checkout HEAD -- test && git clean -fdq -- test && git apply --whitespace=nowarn /tmp/acceptance.patch'
echo "== $case_id / $label: $command"
seed=""; case "$command" in "mix test"*) seed="--seed 0";; esac
docker exec -w /workspace $name sh -c "$command $seed 2>&1" | grep -v 'EAB_\|ESOCK\|ESSIO' | \
  grep -E '^\s+[0-9]+\) test|^\s+(code|left|right|\*\*|Assertion|Expected)|Finished in|tests?, [0-9]+ failure|^Result|error|warning: |^(not )?ok [0-9]|^\s*(✔|✖) |^ℹ (pass|fail) |^# (pass|fail|tests)|^\s+(message|expected|actual):' | head -${LINES_MAX:-60}
