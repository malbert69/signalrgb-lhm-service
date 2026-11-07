const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'ASUS_LHM_Temperatures.js'), 'utf8')
  .replace(/^import .*;\r?\n/m, '').replace(/export function /g, 'function ');
const motherboardId = '/lpc/nct6798d/0/temperature/2';
const vrmId = '/lpc/nct6798d/0/temperature/3';

function harness(plugin = source) {
  const h = { now: 1700000000000, sockets: [], published: [], registered: [], removed: [], controllers: [], announcements: [] };
  h.context = vm.createContext({
    udp: { createSocket() {
      const socket = { handlers: {}, queries: [], closed: false,
        on(name, callback) { this.handlers[name] = callback; }, bind() {},
        write(query, address, port) {
          assert.equal(this.closed, false);
          assert.equal(query.protocol, 2); assert.equal(query.request, 'srgb-lhm/2');
          assert.equal(address, '127.0.0.1'); assert.equal(port, 43871);
          this.queries.push(query);
        }, close() { assert.equal(this.closed, false, 'socket closes only once'); this.closed = true; }
      };
      h.sockets.push(socket); return socket;
    } },
    Date: { now: () => h.now },
    device: { createTemperatureSensor: name => h.registered.push(name),
      SetTemperature: (name, value) => h.published.push([name, value]),
      removeTemperatureSensor: name => h.removed.push(name), log() {} },
    service: { addController: controller => h.controllers.push(controller),
      announceController: controller => h.announcements.push(controller), log() {} }
  });
  vm.runInContext(plugin, h.context);
  h.packet = (changes = {}, socket = h.sockets.at(-1)) => ({
    protocol: 2, status: 'ok', sourceTimeMs: h.now, nonce: socket.queries.at(-1).nonce,
    board: { manufacturer: 'ASUSTeK COMPUTER INC.', model: 'PRIME Z790-P WIFI', version: 'Rev 1.xx' },
    sensors: [{ id: motherboardId, hardware: 'Nuvoton NCT6798D', name: 'Temperature #2', celsius: 31 },
      { id: vrmId, hardware: 'Nuvoton NCT6798D', name: 'Temperature #3', celsius: 39.5 },
      { id: '/unknown/temperature/0', name: 'Unverified raw channel', celsius: 45 }], ...changes
  });
  h.reply = (changes = {}, socket = h.sockets.at(-1)) => {
    socket.handlers.message({ data: JSON.stringify(h.packet(changes, socket)) });
  };
  h.request = (changes = {}) => {
    h.published.length = 0;
    h.now += 1000; h.context.Render(); h.published.length = 0;
    h.reply(changes); h.context.Render();
  };
  return h;
}

const h = harness();
h.context.Initialize(); h.context.Render();
assert.deepEqual(h.registered, ['Motherboard', 'VRM Thermistor']);
h.reply(); h.context.Render();
assert.deepEqual(h.published, [['Motherboard', 31], ['VRM Thermistor', 39.5]]);
console.log('PASS: only verified IDs receive board-specific aliases; extra raw channels stay hidden');

for (const board of [
  { manufacturer: 'ASUSTeK COMPUTER INC.', model: 'PRIME Z790-P' },
  { manufacturer: 'ASUSTeK COMPUTER INC.', model: 'PRIME Z790-P WIFI II' },
  { manufacturer: 'Another manufacturer', model: 'PRIME Z790-P WIFI' },
  { manufacturer: '', model: 'PRIME Z790-P WIFI' }, null
]) {
  h.request({ board }); assert.equal(h.published.length, 0);
}
console.log('PASS: other boards sharing sensor IDs, model variants, missing identity, and wrong manufacturers are rejected');
h.request({ board: { manufacturer: '  asustek   computer inc. ', model: ' prime z790-p wifi ' } });
assert.equal(h.published.length, 2);
console.log('PASS: board matching tolerates casing and whitespace without broad model matching');

h.now += 10001; h.published.length = 0; h.context.Render();
assert.equal(h.published.length, 0);
h.reply({ nonce: 'unsolicited' }); h.context.Render(); assert.equal(h.published.length, 0);
console.log('PASS: stale samples expire and unsolicited replies cannot refresh them');

for (const changes of [
  { protocol: 1 }, { status: 'unavailable' }, { sensors: null },
  { sourceTimeMs: h.now + 60000 }, { sourceTimeMs: h.now - 60000 }, { sourceTimeMs: 'invalid' },
  { sensors: [{ id: motherboardId, celsius: 999 }, { id: vrmId, celsius: null }] },
  { sensors: [{ id: motherboardId, celsius: 30 }, { id: motherboardId, celsius: 40 }] },
  { sensors: [{ id: motherboardId, celsius: null }, { id: motherboardId, celsius: 40 }] },
  { sensors: [{ id: [motherboardId], celsius: 30 }] },
  { sensors: Array.from({ length: 129 }, (_, i) => ({ id: '/unknown/' + i, celsius: 30 })) }
]) {
  h.request(changes); assert.equal(h.published.length, 0);
}
console.log('PASS: legacy protocol, failed reader, invalid timestamps, bad values, and duplicate configured IDs are rejected');
h.request({ detail: 'large raw inventory metadata '.repeat(500) }); assert.equal(h.published.length, 2);
h.request({ detail: 'x'.repeat(60000) }); assert.equal(h.published.length, 0);
console.log('PASS: generic inventories larger than 8 KiB are accepted within the bounded packet limit');
h.request({ sensors: [{ id: motherboardId, celsius: 0 }] });
assert.deepEqual(h.published, [['Motherboard', 0]]);
h.request({ sensors: [{ id: vrmId, celsius: 42 }] });
assert.deepEqual(h.published, [['VRM Thermistor', 42]]);
console.log('PASS: zero degrees and partially available sensors work without replaying missing channels');

h.sockets[0].handlers.error('test error'); h.published.length = 0; h.context.Render();
assert.equal(h.published.length, 0);
h.request(); assert.equal(h.published.length, 2);
h.sockets[0].handlers.message({ data: 'invalid json' }); h.published.length = 0; h.context.Render();
assert.equal(h.published.length, 0);
h.context.Shutdown(); assert.equal(h.sockets[0].closed, true);
assert.deepEqual(h.removed, h.registered);
h.reply(); h.published.length = 0; h.context.Render(); assert.equal(h.published.length, 0);
console.log('PASS: errors stop updates, polling recovers, and shutdown closes the socket and removes sensors');

const d = harness();
const discovery = new d.context.DiscoveryService(); discovery.Initialize();
assert.equal(d.announcements.length, 0);
for (const changes of [
  { board: { manufacturer: 'Other vendor', model: 'Other board' } },
  { board: { manufacturer: 'ASUS', model: 'PRIME Z790-P WIFI II' } },
  { nonce: 'wrong' }, { protocol: 1 }, { status: 'unavailable' },
  { sourceTimeMs: d.now - 60000 }, { sensors: [{ id: '/unknown', celsius: 35 }] }
]) {
  d.reply(changes); assert.equal(d.announcements.length, 0);
  d.now += 60000; discovery.Update();
}
d.sockets[0].handlers.error('service unavailable');
d.now += 60000; discovery.Update();
d.reply();
assert.equal(d.controllers.length, 1); assert.equal(d.announcements.length, 1);
assert.equal(d.controllers[0].id, 'local-asus-z790-lhm-temperatures-v1');
assert.equal(d.sockets[0].closed, true);
discovery.Update(); d.reply(); assert.equal(d.announcements.length, 1);
discovery.Shutdown();
discovery.Initialize(); assert.equal(d.sockets.length, 2);
discovery.Shutdown(); discovery.Shutdown();
console.log('PASS: discovery retries absent/wrong services and announces exactly once after a fresh matching response');

const stopped = harness();
const stoppedDiscovery = new stopped.context.DiscoveryService();
stoppedDiscovery.Initialize(); stoppedDiscovery.Shutdown(); stopped.reply();
assert.equal(stopped.announcements.length, 0); assert.equal(stopped.sockets[0].closed, true);
console.log('PASS: discovery shutdown ignores late replies');

// A second board plugin can use the same service without changing its wire protocol.
const other = harness(source.replace('manufacturers: ["ASUSTeK COMPUTER INC.", "ASUS"]', 'manufacturers: ["Other vendor"]')
  .replace('model: "PRIME Z790-P WIFI"', 'model: "Other board"')
  .replace('controllerId: "local-asus-z790-lhm-temperatures-v1"', 'controllerId: "local-other-board"'));
const otherDiscovery = new other.context.DiscoveryService(); otherDiscovery.Initialize();
other.reply(); assert.equal(other.announcements.length, 0);
other.now += 60000; otherDiscovery.Update();
other.reply({ board: { manufacturer: 'Other vendor', model: 'Other board' } });
assert.equal(other.announcements.length, 1); assert.equal(other.controllers[0].id, 'local-other-board');
console.log('PASS: independent motherboard plugins select their own board from the shared service');
console.log('All plugin tests passed.');
module.exports = { harness };
