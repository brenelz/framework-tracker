#!/bin/bash
set -u
IMG="node:$(cat .nvmrc)-bookworm-slim"; NET=probe; OUT=$PWD/.probe/out; mkdir -p $OUT/prof; chmod -R 777 $OUT
docker network create $NET >/dev/null; docker pull -q $IMG >/dev/null
SOLID="packages/app-solid dist/server/node.js"; SS="packages/app-solid-start .output/server/index.mjs"
AC=/workspace/packages/stats-generator/node_modules/autocannon/autocannon.js
U=$(id -u):$(id -g)
ac() { docker run --rm --network $NET --cpuset-cpus 3 --user $U -v $PWD:/workspace -w /workspace $IMG node "$@"; }
variant() { # label dir entry nodeflags
  local label=$1 dir=$2 entry=$3 flags=${4:-} extra=${5:-}
  docker run -d --name srv --network $NET --cpuset-cpus 0-2 --user $U -v $PWD:/workspace -w /workspace/$dir -e NODE_ENV=production -e HOST=0.0.0.0 -e PORT=3003 $IMG node -r /workspace/.probe/hook.cjs $flags $entry >/dev/null
  for i in $(seq 1 40); do docker run --rm --network $NET $IMG node -e "fetch('http://srv:3003/server-side-rendered').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" >/dev/null 2>&1 && break; sleep 0.5; done
  ac $AC -c 10 -d 15 -H "Accept: text/html,application/xhtml+xml" http://srv:3003/server-side-rendered >/dev/null 2>&1
  docker kill -s USR2 srv >/dev/null
  if [ -n "$extra" ]; then eval "$extra" & fi
  ac $AC -j -c 10 -d 25 -H "Accept: text/html,application/xhtml+xml" http://srv:3003/server-side-rendered 2>/dev/null > $OUT/ac.json
  wait
  docker kill -s TERM srv >/dev/null; sleep 2
  local probe=$(docker logs srv 2>&1 | grep '^PROBE ' | cut -c7-)
  node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[2]));console.log(JSON.stringify({label:process.argv[1],rps:a.requests.average,p50:a.latency.p50,p99:a.latency.p99,bodyKB:Math.round(a.throughput.average/a.requests.average/1024),err:a.errors+a.non2xx,...JSON.parse(process.argv[3]||"{}")}))' "$label" $OUT/ac.json "$probe" | tee -a $OUT/results.jsonl
  docker rm -f srv >/dev/null
}
for round in 1 2 3; do
  variant solid $SOLID
  variant solidstart $SS
  variant solid-coalesced $SOLID "-r /workspace/.probe/coalesce.cjs"
  variant solid-semi64 $SOLID "--max-semi-space-size=64"
  variant solidstart-semi64 $SS "--max-semi-space-size=64"
done
# syscall counts of the server process during load
for pair in "solid|$SOLID" "solidstart|$SS"; do
  l=${pair%%|*}; rest=${pair#*|}
  variant "$l-strace" $rest "" "sudo timeout 15 strace -f -c -p \$(docker inspect -f '{{.State.Pid}}' srv) -o $OUT/strace-$l.txt"
done
# CPU profiles
variant solid-prof $SOLID "--cpu-prof --cpu-prof-dir=/workspace/.probe/out/prof/solid --cpu-prof-interval=500"
variant solidstart-prof $SS "--cpu-prof --cpu-prof-dir=/workspace/.probe/out/prof/solidstart --cpu-prof-interval=500"
