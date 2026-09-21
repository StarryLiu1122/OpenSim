/* V6-5 mission runner: drives the controlled agent surface (V6-4) as an
 * orchestrated multi-step mission and leaves an auditable trail.
 *
 * As a library: const {AgentClient, runMission} = require('./AgentMission.cjs')
 * As a CLI:     node AgentMission.cjs --url=ws://127.0.0.1:PORT/ws --token=HEX --output=DIR
 *
 * Every mission writes two artifacts into the output directory:
 *   observations.jsonl  one JSON line per observation (label, revision, query hits)
 *   receipts.json       every action with task_id, terminal state, code, timings
 * Node built-ins only. */
const fs = require('fs'), path = require('path'), crypto = require('crypto');

const delay = ms => new Promise(r => setTimeout(r, ms));

class AgentClient {
 constructor({url, token}) {
  this.url = url; this.token = token;
  this.results = {}; this.events = []; this.state = null; this.closed = false;
 }
 async connect() {
  this.ws = new WebSocket(this.url);
  this.ws.onerror = () => {};
  this.ws.onclose = e => { this.closed = true; this.closeCode = e.code; this.closeReason = e.reason; };
  this.ws.onmessage = e => {
   const p = JSON.parse(e.data);
   if (p.type === 'welcome') this.welcome = p;
   if (p.type === 'snapshot') this.state = p.state;
   if (p.type === 'delta') { for (const k of ['objects','groups','assets','avatars']) { for (const id of p.delta.deletes[k]) delete this.state[k][id]; Object.assign(this.state[k], p.delta.upserts[k]); } if (p.delta.meta) this.state.meta = p.delta.meta; }
   if (p.type === 'agent_result') this.results[p.request_id] = p;
   if (p.type === 'agent_event') this.events.push(p.task);
   if (p.type === 'snapshot' || p.type === 'delta') this.send({type:'ack', seq:p.seq});
  };
  const end = Date.now() + 15000;
  while (this.ws.readyState !== WebSocket.OPEN && !this.closed) { if (Date.now() > end) throw Error('connect timeout'); await delay(40); }
  if (this.closed) throw Error('connection refused: ' + this.closeReason);
  this.send({type:'hello', token:this.token});
  while (!this.state && !this.closed) { if (Date.now() > end) throw Error('welcome timeout'); await delay(40); }
  if (this.closed) throw Error('authentication failed: ' + this.closeReason);
  return this;
 }
 send(value) { this.ws.send(JSON.stringify({fp_version:'0.3', ...value})); }
 async agent(action, params = {}) {
  const request_id = crypto.randomUUID();
  this.send({type:'agent', request_id, action, params});
  const end = Date.now() + 15000;
  for (;;) { if (this.results[request_id]) return this.results[request_id]; if (Date.now() > end) throw Error('agent_result timeout: ' + action); await delay(40); }
 }
 waitTask(taskId, states = ['completed','failed','timeout','cancelled'], timeout = 130000) {
  const end = Date.now() + timeout;
  return (async () => { for (;;) { const hit = this.events.find(t => t.task_id === taskId && states.includes(t.state)); if (hit) return hit; if (Date.now() > end) throw Error('task event timeout: ' + taskId); await delay(40); } })();
 }
 self() { return this.state.avatars[this.welcome.principal_id]; }
 close() { if (!this.closed) this.ws.close(); }
}

/* The hall-inspection mission: observe at spawn, open the door, walk in,
 * query a named exhibit, operate the lamp, report final states. */
const MISSION = {
 scenario: '展馆巡检：进入展馆、查询指定物体、操作门灯并报告结果',
 query_name: '室内展品', door_name: '展馆伸缩门', lamp_name: '室内照明',
 waypoints: [[128, 131, 1.5], [128, 136, 1.5], [128, 139.5, 1.5]],
};

async function runMission({url, token, output, mission = MISSION, log = console.log}) {
 fs.mkdirSync(output, {recursive:true});
 const observations = path.join(output, 'observations.jsonl');
 const receiptsPath = path.join(output, 'receipts.json');
 const receipts = [];
 const started = Date.now();
 const client = await new AgentClient({url, token}).connect();
 const record = entry => { receipts.push({at_ms: Date.now(), ...entry}); fs.writeFileSync(receiptsPath, JSON.stringify({scenario: mission.scenario, receipts}, null, 1)); };
 const observe = async (label, queryName) => {
  const reply = await client.agent('observe');
  if (!reply.ok) { record({step: label, action: 'observe', ok: false, code: reply.code}); return reply; }
  const state = reply.data.state;
  const entry = {label, at_ms: reply.data.at_ms, revision: reply.data.revision, self: client.self() ? client.self().position : null, objects: Object.keys(state.objects).length};
  if (queryName) {
   entry.query = queryName;
   entry.hits = Object.values(state.objects).filter(o => o.name === queryName).map(o => ({id: o.id, name: o.name, position: o.position, state: o.state, asset_id: o.asset_id}));
  }
  fs.appendFileSync(observations, JSON.stringify(entry) + '\n');
  record({step: label, action: 'observe', ok: true, revision: reply.data.revision, hits: entry.hits ? entry.hits.length : undefined});
  return reply;
 };
 const act = async (label, kind, params) => {
  const submitted = await client.agent('task', {kind, ...params});
  if (!submitted.ok) { record({step: label, kind, ok: false, code: submitted.code}); return {state: 'failed', code: submitted.code}; }
  const task_id = submitted.data.task.task_id;
  const terminal = await client.waitTask(task_id);
  record({step: label, kind, task_id, state: terminal.state, code: terminal.code, detail: terminal.detail, submitted_at_ms: terminal.submitted_at_ms, finished_at_ms: terminal.finished_at_ms});
  return terminal;
 };
 const fail = (step, terminal) => { throw Object.assign(Error('mission step failed: ' + step + ' → ' + terminal.state + '/' + terminal.code), {terminal}); };

 log('mission: observe spawn');
 await observe('01-出生点观察');
 log('mission: open door');
 const door = (await observe('02-定位门', mission.door_name)).data.state;
 const doorTarget = Object.values(door.objects).find(o => o.name === mission.door_name);
 if (!doorTarget) throw Error('door not visible: ' + mission.door_name);
 if ((await act('03-开门', 'set_state', {object_id: doorTarget.id, active: true})).state !== 'completed') fail('03-开门', await Promise.resolve({state:'failed'}));
 for (const [i, point] of mission.waypoints.entries()) {
  log('mission: move_to', point);
  const arrived = await act('04-移动-' + (i + 1), 'move_to', {position: point, tolerance: 0.4, timeout_ms: 30000});
  if (arrived.state !== 'completed') fail('04-移动-' + (i + 1), arrived);
 }
 log('mission: query exhibit');
 const inside = await observe('05-馆内查询', mission.query_name);
 const hit = Object.values(inside.data.state.objects).find(o => o.name === mission.query_name);
 if (!hit) throw Error('query object not visible: ' + mission.query_name);
 log('mission: operate lamp');
 const lampTarget = Object.values(inside.data.state.objects).find(o => o.name === mission.lamp_name);
 if (!lampTarget) throw Error('lamp not visible: ' + mission.lamp_name);
 if ((await act('06-关灯', 'set_state', {object_id: lampTarget.id, active: false})).state !== 'completed') fail('06-关灯', {state:'failed'});
 await observe('07-关灯确认', mission.lamp_name);
 if ((await act('08-开灯', 'set_state', {object_id: lampTarget.id, active: true})).state !== 'completed') fail('08-开灯', {state:'failed'});
 const finalState = await observe('09-终态确认', mission.query_name);
 const finalDoor = Object.values(finalState.data.state.objects).find(o => o.name === mission.door_name);
 const finalLamp = Object.values(finalState.data.state.objects).find(o => o.name === mission.lamp_name);
 client.close();
 const result = {
  ok: true, scenario: mission.scenario, steps: receipts.length,
  started_at_ms: started, finished_at_ms: Date.now(),
  queried: {name: mission.query_name, id: hit.id, position: hit.position},
  final: {door_active: finalDoor.state.active, lamp_active: finalLamp.state.active, self: finalState.data.state.avatars[client.welcome.principal_id] ? finalState.data.state.avatars[client.welcome.principal_id].position : null},
  files: {observations, receipts: receiptsPath},
 };
 fs.writeFileSync(receiptsPath, JSON.stringify({scenario: mission.scenario, result, receipts}, null, 1));
 return result;
}

if (require.main === module) {
 const args = Object.fromEntries(process.argv.slice(2).map(s => { const i = s.indexOf('='); return [s.slice(0, i), s.slice(i + 1)]; }));
 runMission({url: args['--url'], token: args['--token'], output: path.resolve(args['--output'])})
  .then(r => { console.log('MISSION OK', JSON.stringify(r.final)); })
  .catch(e => { console.error('MISSION FAILED', e.message); process.exitCode = 1; });
}
module.exports = {AgentClient, runMission, MISSION};
