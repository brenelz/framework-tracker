const { PerformanceObserver } = require('node:perf_hooks')
const http = require('node:http')
let base = null, gc = { n: 0, ms: 0, kinds: {} }, reqs = 0, writes = 0, drains = 0
new PerformanceObserver((l) => { for (const e of l.getEntries()) { gc.n++; gc.ms += e.duration; const k = e.detail?.kind; gc.kinds[k] = (gc.kinds[k] || 0) + e.duration } }).observe({ entryTypes: ['gc'] })
const ow = http.ServerResponse.prototype.write, oe = http.ServerResponse.prototype.end
http.ServerResponse.prototype.write = function (...a) { writes++; const r = ow.apply(this, a); if (!r) drains++; return r }
http.ServerResponse.prototype.end = function (...a) { reqs++; return oe.apply(this, a) }
const snap = () => ({ r: process.resourceUsage(), t: performance.now(), el: performance.eventLoopUtilization() })
process.on('SIGUSR2', () => { base = snap(); gc = { n: 0, ms: 0, kinds: {} }; reqs = 0; writes = 0; drains = 0 })
process.on('SIGTERM', () => {
  const s = snap(); const b = base ?? { r: { userCPUTime: 0, systemCPUTime: 0, voluntaryContextSwitches: 0, involuntaryContextSwitches: 0, maxRSS: 0 }, t: 0, el: s.el }
  const per = (x) => +(x / Math.max(reqs, 1)).toFixed(3)
  const elu = performance.eventLoopUtilization(s.el, b.el)
  console.log('PROBE ' + JSON.stringify({ seconds: +((s.t - b.t) / 1000).toFixed(1), reqs, reqsPerSec: +(reqs / ((s.t - b.t) / 1000)).toFixed(1), userMsPerReq: per((s.r.userCPUTime - b.r.userCPUTime) / 1000), sysMsPerReq: per((s.r.systemCPUTime - b.r.systemCPUTime) / 1000), gcMsPerReq: per(gc.ms), gcCount: gc.n, gcKinds: gc.kinds, writesPerReq: per(writes), drainsPerReq: per(drains), volCtxPerReq: per(s.r.voluntaryContextSwitches - b.r.voluntaryContextSwitches), involCtxPerReq: per(s.r.involuntaryContextSwitches - b.r.involuntaryContextSwitches), elu: +elu.utilization.toFixed(3), maxRSSMB: Math.round(s.r.maxRSS / 1024), cpus: require('os').availableParallelism() }))
  process.exit(0)
})
