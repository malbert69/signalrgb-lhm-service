const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { harness } = require('./test-plugin.cjs');
const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, 'plugins', 'catalog.json'), 'utf8'));
const controllers = new Set(['local-asus-z790-lhm-temperatures-v1']);
let combinations = 0, aliases = 0;

function sourceFor(entry) {
  return fs.readFileSync(path.join(__dirname, 'plugins', entry.filename), 'utf8')
    .replace(/^import .*;\r?\n/m, '').replace(/export function /g, 'function ');
}
function readings(variant, chip, hardwareIndex = 0) {
  return variant.sensors.map((sensor, i) => ({ id: `/lpc/${chip}/${hardwareIndex}/temperature/${sensor.index}`,
    hardware: chip, name: sensor.name, celsius: 30 + i }));
}

for (const entry of catalog.entries) {
  assert.equal(controllers.has(entry.controllerId), false, entry.filename + ': duplicate controller ID');
  controllers.add(entry.controllerId);
  assert.equal(entry.validation, 'upstream-derived; hardware untested');
  const plugin = sourceFor(entry);
  const h = harness(plugin);
  const board = { manufacturer: entry.manufacturers[0], model: entry.models[0], version: 'fixture' };
  h.context.Initialize(); h.context.Render();
  const expectedNames = [...new Set(entry.variants.flatMap(v => v.sensors.map(s => s.displayName)))].sort();
  assert.deepEqual(h.registered.slice().sort(), expectedNames, entry.filename + ': register each name once');
  for (const variant of entry.variants) for (const chip of variant.chips) {
    const sensors = readings(variant, chip);
    h.request({ board, sensors });
    assert.deepEqual(h.published, variant.sensors.map((s, i) => [s.displayName, 30 + i]), entry.filename + ': ' + chip + ' channel identities');
    combinations++;
  }
  const variant = entry.variants[0];
  const sensors = readings(variant, variant.chips[0]);
  for (const model of entry.models) for (const manufacturer of entry.manufacturers) {
    h.request({ board: { model, manufacturer }, sensors });
    assert.equal(h.published.length, sensors.length, entry.filename + ': exact identity alias'); aliases++;
  }
  for (const changes of [
    { board: { ...board, model: board.model + ' NOT THIS BOARD' } },
    { board: { ...board, manufacturer: 'Unrelated manufacturer' } },
    { board: null }, { protocol: 1 }, { sourceTimeMs: 0 },
    { sensors: sensors.map(s => ({ ...s, name: 'Wrong raw LHM name' })) },
    { sensors: readings(variant, variant.chips[0], 1) },
    { sensors: sensors.map(s => ({ ...s, id: s.id.replace(variant.chips[0], 'unknown-chip') })) }
  ]) {
    h.request({ board, sensors, ...changes });
    assert.equal(h.published.length, 0, entry.filename + ': reject mismatching board/channel data');
  }
  h.context.Shutdown(); assert.deepEqual(h.removed, h.registered);
  const d = harness(plugin);
  const discovery = new d.context.DiscoveryService(); discovery.Initialize();
  d.reply({ board: { ...board, model: board.model + ' NOT THIS BOARD' }, sensors });
  assert.equal(d.announcements.length, 0);
  const initialRequests = d.sockets[0].queries.length;
  d.now += 5000; discovery.Update();
  assert.equal(d.sockets[0].queries.length, initialRequests, 'nonmatching plugin backs off');
  d.now += 55000; discovery.Update();
  d.reply({ board, sensors });
  assert.equal(d.announcements.length, 1, entry.filename + ': discover matching motherboard');
  assert.equal(d.controllers[0].id, entry.controllerId);
  assert.equal(d.sockets[0].closed, true);
  discovery.Shutdown();
}

// Independent spot checks of explicit upstream rows catch index/name extraction mistakes.
function hasSensor(model, chip, index, name) {
  const entry = catalog.entries.find(e => e.modelEnum === model);
  assert.ok(entry, model);
  const h = harness(sourceFor(entry));
  const definitions = JSON.parse(vm.runInContext('JSON.stringify(SENSOR_DEFINITIONS)', h.context));
  assert.equal(definitions[`/lpc/${chip}/0/temperature/${index}`]?.nativeName, name, model + ' reference mapping');
}
hasSensor('ROG_MAXIMUS_Z790_HERO', 'nct6798d', 2, 'Motherboard');
hasSensor('ROG_MAXIMUS_Z790_HERO', 'nct6798d', 13, 'Chipset');
hasSensor('B550A_PRO', 'nct6687d', 2, 'VRM MOS');
hasSensor('X870E_TAICHI', 'nct6687d', 2, 'VRM MOS');
hasSensor('X570_AORUS_MASTER', 'it8688e', 4, 'VRM MOS');

console.log(`PASS: ${catalog.entries.length} generated plugins; ${combinations} chip/mapping combinations; ${aliases} manufacturer/model alias combinations`);
console.log('PASS: every plugin rejects wrong boards, wrong raw names, unsupported chips, secondary chips, old protocol, and stale data');
console.log('PASS: every plugin registers unique names, respects discovery backoff, announces its own controller, and cleans up');
console.log('PASS: independent ASUS, ASRock, MSI, and Gigabyte channel reference checks');
