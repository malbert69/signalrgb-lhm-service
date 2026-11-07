const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const dgram = require('node:dgram');
const { once } = require('node:events');
const socket = dgram.createSocket('udp4');
const readings = [], timestamps = new Set();
let serviceLastSeen = 0;
const adapter = {
  on(event, callback) {
    if (event === 'message') socket.on('message', (bytes, remote) => {
      assert.equal(remote.address, '127.0.0.1');
      try { const packet = JSON.parse(bytes.toString('utf8')); if (packet.protocol === 2 && packet.status === 'ok' && packet.board) { timestamps.add(packet.sourceTimeMs); serviceLastSeen = Date.now(); } } catch (_) {}
      callback({ data: bytes.toString('utf8'), address: remote.address });
    });
    else socket.on(event, callback);
  },
  bind: () => socket.bind(0, '127.0.0.1'),
  write: (query, host, port) => socket.send(Buffer.from(JSON.stringify(query)), port, host),
  close: () => socket.close()
};
const context = vm.createContext({ udp: { createSocket: () => adapter }, Date,
  device: { createTemperatureSensor() {}, removeTemperatureSensor() {}, log: console.log,
    SetTemperature: (name, value) => readings.push({ name, value, time: Date.now() }) },
  service: { addController() {}, announceController() {}, log() {} } });
vm.runInContext(fs.readFileSync(path.join(__dirname, 'ASUS_LHM_Temperatures.js'), 'utf8')
  .replace(/^import .*;\r?\n/m, '').replace(/export function /g, 'function '), context);
(async () => {
  context.Initialize();
  await once(socket, 'listening');
  const start = Date.now();
  while (Date.now() - start < 26000) {
    context.Render();
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  context.Shutdown();
  assert.ok(readings.some(r => r.name === 'Motherboard'), 'Motherboard temperature reached the plugin');
  assert.ok(readings.some(r => r.name === 'VRM Thermistor'), 'VRM temperature reached the plugin');
  assert.ok(timestamps.size >= 2, 'multiple actual native samples were received');
  assert.ok(readings.every(r => Number.isFinite(r.value)), 'all delivered readings are finite');
  assert.ok(serviceLastSeen && Date.now() - serviceLastSeen > 10000, 'temporary service ended before stale check');
  assert.ok(Date.now() - readings.at(-1).time > 4000, 'plugin stopped publishing after native updates expired');
  const latest = Object.fromEntries(readings.map(r => [r.name, r.value]));
  console.log(JSON.stringify({ result: 'PASS', nativeSamples: timestamps.size, latest,
    staleSourceStoppedPublishing: true }, null, 2));
})().catch(error => { console.error(error); try { socket.close(); } catch (_) {} process.exitCode = 1; });
