const http = require('node:http')
const ow = http.ServerResponse.prototype.write, oe = http.ServerResponse.prototype.end
http.ServerResponse.prototype.write = function (c) { (this.__b ??= []).push(Buffer.from(c.buffer, c.byteOffset, c.byteLength)); return true }
http.ServerResponse.prototype.end = function (...a) { if (this.__b) { const b = Buffer.concat(this.__b); this.__b = null; ow.call(this, b) } return oe.apply(this, a) }
