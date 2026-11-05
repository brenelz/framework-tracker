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
  ac $AC -c 10 -d 15 -H "Accept: text/html,application/xhtml+xml" http://srv:3003${TARGET:-/server-side-rendered} >/dev/null 2>&1
  docker kill -s USR2 srv >/dev/null
  if [ -n "$extra" ]; then eval "$extra" & fi
  ac $AC -j -c 10 -d 25 -H "Accept: text/html,application/xhtml+xml" http://srv:3003${TARGET:-/server-side-rendered} 2>/dev/null > $OUT/ac.json
  wait
  docker kill -s TERM srv >/dev/null; sleep 2
  local probe=$(docker logs srv 2>&1 | grep '^PROBE ' | cut -c7-)
  node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[2]));console.log(JSON.stringify({label:process.argv[1],rps:a.requests.average,p50:a.latency.p50,p99:a.latency.p99,bodyKB:Math.round(a.throughput.average/a.requests.average/1024),err:a.errors+a.non2xx,...JSON.parse(process.argv[3]||"{}")}))' "$label" $OUT/ac.json "$probe" | tee -a $OUT/results.jsonl
  docker rm -f srv >/dev/null
}

# Variants of the same Solid build, patched in copies of dist.
A=packages/app-solid
for v in fastbase noclaims; do cp -r $A/dist $A/dist-$v; done
sed -i 's/^function isUnderBase(pathname, base) {$/function isUnderBase(pathname, base) {\n\tif (!base || base === "\/") return true;/' $A/dist-fastbase/server/server.js
sed -i 's/^function managedLinkUrl(a, explicitLinks, page, origin, basePath) {$/function managedLinkUrl(a, explicitLinks, page, origin, basePath) {\n\treturn;/' $A/dist-noclaims/server/server.js
grep -c 'base === "/") return true' $A/dist-fastbase/server/server.js
grep -A1 '^function managedLinkUrl' $A/dist-noclaims/server/server.js | tail -1
SF=$(ls -d $A/node_modules/.pnpm/@solidjs+web@2.0.0-rc.21*/node_modules/@solidjs/web/server-functions/dist/server.js)
cp "$SF" $OUT/sf.bak
scope_off() { sed -i 's/^function scopeDeferredResult(value, scope) {$/function scopeDeferredResult(value, scope) {\n  return value;/' "$SF"; }
scope_on() { cp $OUT/sf.bak "$SF"; }
for round in 1 2 3; do
  variant solid $SOLID
  variant solidstart $SS
  variant solid-fastbase $A dist-fastbase/server/node.js
  variant solid-noclaims $A dist-noclaims/server/node.js
  scope_off; variant solid-noscope $SOLID; scope_on
  TARGET=/ssr-throughput variant solid-nolinks-page $SOLID
  TARGET=/ssr-throughput variant solidstart-nolinks-page $SS
done
rm -f $OUT/sf.bak
