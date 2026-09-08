#!/usr/bin/env node
// kyzu_raider_bot.js - an external AI controller for kyzu, connected
// entirely over the VDRX WebSocket bus - no access to kyzu's source,
// no special privileges, just the same game.cmd.*/game.event.* protocol
// the browser map viewer uses. This is the concrete starting point for
// "different AI controllers via the bus" - copy this file, change
// FACTION_NAME and the decide() function, run both at once, and you
// have two independent strategies playing against each other and
// against a human in the browser, all watching the same live game.
//
// Strategy here is deliberately the OPPOSITE of the embedded economy
// AI (kyzu.lpr's RunAI): that one is purely passive/economic (spawn
// workers, collect resources, never fights). This one is a raider -
// it spawns soldiers and hunts down the nearest enemy unit or city.
// Two very different personalities, same protocol, same bus.
//
// Requires Node 22+ for the native global WebSocket (no npm install,
// matching kyzu's own zero-dependency conventions). Run with:
//   node kyzu_raider_bot.js [ws://host:port] [faction_name]

const WS_URL = process.argv[2] || 'ws://127.0.0.1:8181';
const FACTION_NAME = process.argv[3] || 'raider';
const AUTH_TOKEN = 'bot'; // VDRX's sys.auth is a stub - any nonempty token passes (see vdrx_network.pas)
const DECIDE_INTERVAL_MS = 2000;
const TARGET_SOLDIER_COUNT = 2;
const HOME_LON = 22.0, HOME_LAT = 14.0; // pick a spot on your own map's passable terrain

// ── Local world model, rebuilt entirely from the event stream - the
// bot has no other source of truth, same as the browser client. ──
const units = new Map();   // unit_id -> {owner, unitType, lon, lat, hp}
const cities = new Map();  // city_id -> {owner, lon, lat, population}

let ws;
let nextId = 0;
function newId(prefix) { return prefix + '_' + FACTION_NAME + '_' + (Date.now().toString(36)) + '_' + (nextId++); }

function publish(topic, payload) {
  ws.send(JSON.stringify({ method: 'publish', topic, payload }));
}

function distance(ax, ay, bx, by) {
  return Math.hypot(ax - bx, ay - by);
}

// ── Strategy: keep TARGET_SOLDIER_COUNT soldiers alive, and once any
// exist, send each idle one after the nearest enemy unit or city. ──
function decide() {
  let mySoldiers = 0;
  for (const u of units.values()) {
    if (u.owner === FACTION_NAME && u.unitType === 'soldier') mySoldiers++;
  }

  if (mySoldiers < TARGET_SOLDIER_COUNT) {
    publish('game.cmd.spawn', {
      unit_id: newId('u'),
      lon: HOME_LON, lat: HOME_LAT,
      owner: FACTION_NAME, unit_type: 'soldier'
    });
  }

  for (const [id, u] of units) {
    if (u.owner !== FACTION_NAME || u.unitType !== 'soldier') continue;

    // Nearest enemy unit
    let bestUnit = null, bestUnitDist = Infinity;
    for (const [tid, t] of units) {
      if (t.owner === FACTION_NAME || t.owner === '') continue;
      const d = distance(u.lon, u.lat, t.lon, t.lat);
      if (d < bestUnitDist) { bestUnitDist = d; bestUnit = tid; }
    }

    // Nearest enemy city
    let bestCity = null, bestCityDist = Infinity;
    for (const [cid, c] of cities) {
      if (c.owner === FACTION_NAME) continue;
      const d = distance(u.lon, u.lat, c.lon, c.lat);
      if (d < bestCityDist) { bestCityDist = d; bestCity = cid; }
    }

    const targetIsUnit = bestUnit && bestUnitDist <= bestCityDist;
    const targetLon = targetIsUnit ? units.get(bestUnit).lon : (bestCity ? cities.get(bestCity).lon : null);
    const targetLat = targetIsUnit ? units.get(bestUnit).lat : (bestCity ? cities.get(bestCity).lat : null);
    if (targetLon === null) continue; // nothing to fight anywhere yet

    const targetDist = targetIsUnit ? bestUnitDist : bestCityDist;

    if (targetDist <= 1.5) {
      // In range - attack directly (server enforces the real range
      // check; 1.5 here just avoids issuing a doomed-to-fail attack
      // from obviously too far away).
      publish('game.cmd.attack', targetIsUnit
        ? { attacker_unit_id: id, target_unit_id: bestUnit, by: FACTION_NAME }
        : { attacker_unit_id: id, target_city_id: bestCity, by: FACTION_NAME });
    } else {
      publish('game.cmd.move', { unit_id: id, to_lon: targetLon, to_lat: targetLat, by: FACTION_NAME });
    }
  }
}

function connect() {
  ws = new WebSocket(WS_URL);

  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({ method: 'sys.auth', token: AUTH_TOKEN }));
  });

  ws.addEventListener('message', (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch (e) { return; }

    if (msg.event === 'auth.ok') {
      console.log(`[${FACTION_NAME}] authenticated as ${msg.source}, subscribing...`);
      ws.send(JSON.stringify({ method: 'subscribe', filter: 'game.>' }));
      setInterval(decide, DECIDE_INTERVAL_MS);
      return;
    }

    if (!msg.topic) return;
    let payload = msg.payload;
    if (typeof payload === 'string') {
      try { payload = JSON.parse(payload); } catch (e) { return; }
    }

    if (msg.topic === 'game.event.spawned') {
      units.set(payload.unit_id, { owner: payload.owner, unitType: payload.unit_type, lon: payload.lon, lat: payload.lat, hp: payload.hp });
    } else if (msg.topic === 'game.event.position') {
      const u = units.get(payload.unit_id);
      if (u) { u.lon = payload.lon; u.lat = payload.lat; }
    } else if (msg.topic === 'game.event.despawned') {
      units.delete(payload.unit_id);
    } else if (msg.topic === 'game.event.unit_attacked') {
      const u = units.get(payload.target_unit_id);
      if (u) u.hp = payload.remaining_hp;
    } else if (msg.topic === 'game.event.city_founded' || msg.topic === 'game.event.city_grew' || msg.topic === 'game.event.city_captured') {
      const existing = cities.get(payload.city_id) || {};
      cities.set(payload.city_id, {
        owner: payload.owner ?? payload.new_owner ?? existing.owner,
        lon: payload.lon ?? existing.lon,
        lat: payload.lat ?? existing.lat,
        population: payload.population ?? existing.population
      });
    } else if (msg.topic === 'game.event.city_abandoned') {
      cities.delete(payload.city_id);
    }
  });

  ws.addEventListener('close', () => {
    console.log(`[${FACTION_NAME}] disconnected, reconnecting in 3s...`);
    setTimeout(connect, 3000);
  });

  ws.addEventListener('error', (ev) => {
    console.log(`[${FACTION_NAME}] connection error:`, ev.message || ev);
  });
}

console.log(`[${FACTION_NAME}] connecting to ${WS_URL} ...`);
connect();
