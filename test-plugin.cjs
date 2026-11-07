const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const published = [], registered = [], queries = [];
const handlers = {};
let now = 1700000000000;
const socket = { on(name, callback) { handlers[name] = callback; }, bind() {},
  write(query, address, port) { queries.push(query); assert.equal(address, '127.0.0.1'); assert.equal(port, 43871); }, close() {} };
const context = vm.createContext({ udp: { createSocket: () => socket }, Date: { now: () => now },
  device: { createTemperatureSensor: name => registered.push(name), SetTemperature: (name, value) => published.push([name, value]),
    removeTemperatureSensor() {}, log() {} }, service: { addController() {}, announceController() {}, log() {} } });
const source = fs.readFileSync(path.join(__dirname, 'ASUS_LHM_Temperatures.js'), 'utf8')
  .replace(/^import .*;\r?\n/m, '').replace(/export function /g, 'function ');
vm.runInContext(source, context);
context.Initialize();
assert.deepEqual(registered, ['Motherboard', 'VRM Thermistor']);
context.Render();
const good = () => ({ protocol: 1, status: 'ok', sourceTimeMs: now, nonce: queries.at(-1).nonce,
  sensors: [{ id: '/lpc/nct6798d/0/temperature/2', name: 'ignored wire label', celsius: 31 }] });
handlers.message({ data: JSON.stringify(good()) });
context.Render();
assert.deepEqual(published.pop(), ['Motherboard', 31]);
console.log('PASS: stable ID maps to the registered motherboard temperature');
now += 10001; published.length = 0;
context.Render(); assert.equal(published.length, 0);
console.log('PASS: an expired sample is never refreshed from cache');
handlers.message({ data: JSON.stringify({ ...good(), nonce: 'unsolicited', sensors: good().sensors }) });
context.Render(); assert.equal(published.length, 0);
console.log('PASS: unsolicited replies are rejected');
handlers.message({ data: JSON.stringify({ ...good(), sensors: [{ id: 'unverified', celsius: 38 },
  { id: good().sensors[0].id, celsius: 999 }] }) });
context.Render(); assert.equal(published.length, 0);
console.log('PASS: unconfigured IDs and impossible values are rejected');
handlers.message({ data: JSON.stringify({ ...good(), sourceTimeMs: now + 60000 }) });
context.Render(); assert.equal(published.length, 0);
console.log('PASS: invalid source timestamps are rejected');
handlers.message({ data: JSON.stringify(good()) }); context.Render(); assert.equal(published.length, 1);
published.length = 0;
handlers.message({ data: JSON.stringify({ ...good(), status: 'unavailable', sensors: [] }) });
context.Render(); assert.equal(published.length, 0);
console.log('PASS: native reader failure stops temperature updates');
handlers.message({ data: JSON.stringify({ ...good(), sensors: [{ ...good().sensors[0], celsius: 0 }] }) });
context.Render(); assert.deepEqual(published.pop(), ['Motherboard', 0]);
console.log('PASS: valid zero-degree temperatures are preserved');
handlers.message({ data: 'invalid json' }); context.Render(); assert.equal(published.length, 0);
context.Shutdown();
console.log('All plugin tests passed.');
