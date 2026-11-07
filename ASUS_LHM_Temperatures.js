import udp from "@SignalRGB/udp";

export function Name() { return "ASUS Motherboard Temperatures (LHM)"; }
export function Version() { return "0.1.0"; }
export function Publisher() { return "Local custom plugin"; }
export function Type() { return "network"; }
export function Size() { return [1, 1]; }
export function DefaultPosition() { return [0, 0]; }
export function DefaultScale() { return 1; }
export function LedNames() { return []; }
export function LedPositions() { return []; }
export function SupportsFanControl() { return true; }

const SENSOR_NAMES = {
    "/lpc/nct6798d/0/temperature/2": "Motherboard",
    "/lpc/nct6798d/0/temperature/3": "VRM Thermistor"
};
const MAX_AGE_MS = 10000;
let socket;
let lastPoll = 0;
let latest;
let lastReceived = 0;
let previousState = "";
let pendingNonce;

export function Initialize() {
    for (const id of Object.keys(SENSOR_NAMES)) device.createTemperatureSensor(SENSOR_NAMES[id]);
    socket = udp.createSocket();
    socket.on("message", onMessage);
    socket.on("error", function (error, message) {
        latest = undefined;
        device.log("Native sensor socket error: " + (message || error));
    });
    socket.bind(0);
    device.log("Connecting to the LibreHardwareMonitor service on 127.0.0.1:43871");
}

function onMessage(message) {
    const text = message && message.data !== undefined ? message.data : message;
    if (typeof text !== "string" || text.length > 8192) return;
    try {
        const packet = JSON.parse(text);
        if (!pendingNonce || packet.nonce !== pendingNonce) return;
        if (packet.protocol !== 1 || packet.status !== "ok" || !Array.isArray(packet.sensors)) {
            latest = undefined;
            return;
        }
        const age = Date.now() - packet.sourceTimeMs;
        if (!Number.isFinite(packet.sourceTimeMs) || age > MAX_AGE_MS || age < -2000) {
            latest = undefined;
            return;
        }
        const values = {};
        for (const reading of packet.sensors) {
            if (!reading || !Object.prototype.hasOwnProperty.call(SENSOR_NAMES, reading.id)) continue;
            if (typeof reading.celsius !== "number" || !Number.isFinite(reading.celsius) ||
                reading.celsius < -20 || reading.celsius > 150) continue;
            values[reading.id] = reading.celsius;
        }
        latest = { sourceTimeMs: packet.sourceTimeMs, values: values };
        lastReceived = Date.now();
    } catch (_) { latest = undefined; }
}

export function Render() {
    const now = Date.now();
    if (now - lastPoll >= 1000) {
        lastPoll = now;
        pendingNonce = now.toString(16) + "-" + Math.random().toString(16).slice(2);
        try { socket.write({ protocol: 1, request: "srgb-lhm/1", nonce: pendingNonce }, "127.0.0.1", 43871); }
        catch (_) { latest = undefined; }
    }
    const fresh = latest && now - lastReceived <= MAX_AGE_MS && now - latest.sourceTimeMs <= MAX_AGE_MS &&
        latest.sourceTimeMs <= now + 2000;
    const state = fresh && Object.keys(latest.values).length ? "receiving" : "unavailable";
    if (state !== previousState) { device.log("Native motherboard sensors: " + state); previousState = state; }
    if (!fresh) return;
    for (const id of Object.keys(latest.values)) device.SetTemperature(SENSOR_NAMES[id], latest.values[id]);
}

export function Shutdown() {
    latest = undefined;
    if (socket) socket.close();
    for (const id of Object.keys(SENSOR_NAMES)) device.removeTemperatureSensor(SENSOR_NAMES[id]);
}

export function DiscoveryService() {
    this.Initialize = function () {
        const controller = { id: "local-asus-z790-lhm-temperatures-v1", ip: "127.0.0.1",
            name: "ASUS PRIME Z790-P WIFI Temperatures" };
        service.addController(controller);
        service.announceController(controller);
        service.log("Announced local LibreHardwareMonitor temperature provider");
    };
    this.Update = function () {};
}
