#!/bin/bash
# SSR load for app-solid with three router builds: main, solidjs/solid-router#748, claim handler off.
set -u
IMG="node:$(cat .nvmrc)-bookworm-slim"; NET=probe; OUT=$PWD/.probe/out; mkdir -p $OUT; chmod -R 777 $OUT
docker network create $NET >/dev/null; docker pull -q $IMG >/dev/null
AC=/workspace/packages/stats-generator/node_modules/autocannon/autocannon.js
U=$(id -u):$(id -g)
ac() { docker run --rm --network $NET --cpuset-cpus 3 --user $U -v $PWD:/workspace -w /workspace $IMG node "$@"; }
variant() { # label dir
  local label=$1 dir=$2
  docker run -d --name srv --network $NET --cpuset-cpus 0-2 --user $U -v $PWD:/workspace -w /workspace/$dir -e NODE_ENV=production -e HOST=0.0.0.0 -e PORT=3003 $IMG node -r /workspace/.probe/hook.cjs dist/server/node.js >/dev/null
  for i in $(seq 1 40); do docker run --rm --network $NET $IMG node -e "fetch('http://srv:3003/server-side-rendered').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" >/dev/null 2>&1 && break; sleep 0.5; done
  ac $AC -c 10 -d 10 -H "Accept: text/html" http://srv:3003/server-side-rendered >/dev/null 2>&1
  docker kill -s USR2 srv >/dev/null
  ac $AC -j -c 10 -d 20 -H "Accept: text/html" http://srv:3003/server-side-rendered 2>>$OUT/ac-stderr.log > $OUT/ac.json
  docker kill -s TERM srv >/dev/null; sleep 2
  docker logs srv > $OUT/srv-$label-$ROUND.log 2>&1
  local probe=$(docker logs srv 2>&1 | grep '^PROBE ' | cut -c7-)
  node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[3]));console.log(JSON.stringify({round:+process.argv[2],label:process.argv[1],rps:a.requests.average,p50:a.latency.p50,p99:a.latency.p99,err:a.errors+a.non2xx,...JSON.parse(process.argv[4]||"{}")}))' "$label" "$ROUND" $OUT/ac.json "$probe" | tee -a $OUT/results.jsonl
  docker rm -f srv >/dev/null
}
ls -la packages/stats-generator/node_modules/autocannon || true
ac $AC --version || echo "autocannon failed to start"
V=(base pr748 off)
for ROUND in 1 2 3 4 5 6; do
  for i in 0 1 2; do v=${V[$(( (i + ROUND) % 3 ))]}; variant $v packages/app-solid-$v; done
done
node -e '
const rows=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
const med=a=>{const s=[...a].sort((x,y)=>x-y),n=s.length;return n%2?s[(n-1)/2]:(s[n/2-1]+s[n/2])/2};
for (const v of ["base","pr748","off"]) { const x=rows.filter(r=>r.label===v);
  console.log(v.padEnd(6), "rps median", med(x.map(r=>r.rps)).toFixed(0), "range", Math.min(...x.map(r=>r.rps)).toFixed(0)+"-"+Math.max(...x.map(r=>r.rps)).toFixed(0),
    "| user+sys ms/req", med(x.map(r=>r.userMsPerReq+r.sysMsPerReq)).toFixed(3), "| gc ms/req", med(x.map(r=>r.gcMsPerReq)).toFixed(3), "| p99", med(x.map(r=>r.p99))) }' $OUT/results.jsonl | tee $OUT/summary.txt
