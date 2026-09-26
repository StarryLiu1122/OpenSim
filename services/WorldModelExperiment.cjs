/* Apply one validated V6.1 water-prediction batch as local markers in a
 * running Region Lab FP 0.3 world. Node 24 built-ins only.
 *
 * This is an experiment overlay: a sample is a measured/predicted point, not
 * a flood polygon, simulated water surface or road-closure determination.
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {AgentClient} = require('./AgentMission.cjs');

const FP = '0.3';
const BOX = '22222222-2222-4222-8222-222222222222';
const FORMAT = 'region-lab.world-model-input';
const MAX_INPUT = 1024 * 1024;
const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/;
const SHA = /^[0-9a-f]{64}$/;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const finite = value => typeof value === 'number' && Number.isFinite(value);
const close = (a, b) => Math.abs(a - b) <= 1e-6;
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));

function readJson(filename, label) {
  const bytes = fs.readFileSync(filename);
  if (bytes.length > MAX_INPUT) throw Error(`${label} exceeds 1 MiB`);
  return {bytes, value: JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, ''))};
}

function deterministicId(...parts) {
  const bytes = crypto.createHash('sha256').update(JSON.stringify(['world-model-experiment-v1', ...parts])).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const h = bytes.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

function validateInputs({observation, manifest, input}) {
  const normalized = readJson(observation, 'normalized observation');
  const scene = readJson(manifest, 'scene manifest');
  const original = readJson(input, 'original model input');
  const n = normalized.value, m = scene.value, raw = original.value;
  const keys = ['format', 'version', 'batch_id', 'source_id', 'model_id', 'model_version',
    'source_crs', 'observed_at', 'generated_at', 'predicted_for', 'samples',
    'manifest_sha256', 'input_sha256'];
  if (!exact(n, keys) || n.format !== FORMAT || n.version !== 1 || !SHA.test(n.manifest_sha256)
    || !SHA.test(n.input_sha256)) throw Error('invalid normalized observation format');
  if (hash(scene.bytes) !== n.manifest_sha256) throw Error('manifest_sha256 mismatch');
  if (hash(original.bytes) !== n.input_sha256) throw Error('input_sha256 mismatch');
  const rawKeys = ['schema_version', 'batch_id', 'source_id', 'model_id', 'model_version',
    'source_crs', 'horizontal_unit', 'vertical_unit', 'observed_at', 'generated_at',
    'predicted_for', 'samples'];
  if (!exact(raw, rawKeys) || raw.schema_version !== 1 || raw.horizontal_unit !== 'metre'
    || raw.vertical_unit !== 'metre') throw Error('invalid original model input');
  for (const key of ['batch_id', 'source_id', 'model_id', 'model_version']) {
    if (typeof n[key] !== 'string' || !ID.test(n[key]) || n[key] !== raw[key])
      throw Error(`${key} identity mismatch`);
  }
  for (const key of ['source_crs', 'observed_at', 'generated_at', 'predicted_for']) {
    if (typeof n[key] !== 'string' || n[key] !== raw[key]) throw Error(`${key} mismatch`);
  }
  if (!m || m.source_crs !== n.source_crs || !Array.isArray(m.source_bounds)
    || m.source_bounds.length !== 4 || !m.source_bounds.every(finite)
    || !Array.isArray(m.region_offset) || m.region_offset.length !== 2
    || !m.region_offset.every(finite) || !finite(m.height_baseline_source)
    || !finite(m.region_size) || ![256, 512].includes(m.region_size)
    || typeof m.region_name !== 'string' || !m.region_name.trim())
    throw Error('scene manifest coordinate mapping is invalid');
  if (m.source_bounds[0] >= m.source_bounds[2] || m.source_bounds[1] >= m.source_bounds[3])
    throw Error('scene manifest bounds are inverted');
  if (!Array.isArray(n.samples) || !Array.isArray(raw.samples)
    || n.samples.length < 1 || n.samples.length > 256 || n.samples.length !== raw.samples.length)
    throw Error('sample count mismatch');
  const byId = new Map();
  for (const sample of raw.samples) {
    if (!exact(sample, ['id', 'east', 'north', 'water_surface_height'])
      || typeof sample.id !== 'string' || !ID.test(sample.id) || byId.has(sample.id)
      || ![sample.east, sample.north, sample.water_surface_height].every(finite))
      throw Error('invalid or duplicate original sample');
    byId.set(sample.id, sample);
  }
  const seen = new Set();
  for (const sample of n.samples) {
    if (!exact(sample, ['id', 'source_position', 'region_position'])
      || typeof sample.id !== 'string' || seen.has(sample.id) || !byId.has(sample.id)
      || !Array.isArray(sample.source_position) || sample.source_position.length !== 3
      || !Array.isArray(sample.region_position) || sample.region_position.length !== 3
      || !sample.source_position.every(finite) || !sample.region_position.every(finite))
      throw Error('invalid or duplicate normalized sample');
    seen.add(sample.id);
    const originalSample = byId.get(sample.id);
    const source = [originalSample.east, originalSample.north, originalSample.water_surface_height];
    const mapped = [m.region_offset[0] + source[0] - m.source_bounds[0],
      m.region_offset[1] + source[1] - m.source_bounds[1], source[2] - m.height_baseline_source];
    if (!source.every((v, i) => close(v, sample.source_position[i]))
      || !mapped.every((v, i) => close(v, sample.region_position[i])))
      throw Error(`sample ${sample.id} mapping mismatch`);
    if (source[0] < m.source_bounds[0] || source[0] > m.source_bounds[2]
      || source[1] < m.source_bounds[1] || source[1] > m.source_bounds[3]
      || mapped[0] < 0.4 || mapped[0] > m.region_size - 0.4
      || mapped[1] < 0.4 || mapped[1] > m.region_size - 0.4
      || mapped[2] < -39.6 || mapped[2] > 119.6)
      throw Error(`sample ${sample.id} cannot be represented by a local marker`);
  }
  return {normalized: n, manifest: m,
    hashes: {observation_sha256: hash(normalized.bytes), manifest_sha256: n.manifest_sha256,
      input_sha256: n.input_sha256}};
}

function markerName(sample) {
  const level = sample.source_position[2].toFixed(2);
  const prefix = '预测点 · ', suffix = ` · ${level} m`;
  const maxId = 80 - prefix.length - suffix.length;
  return prefix + sample.id.slice(0, maxId) + suffix;
}

function makeObject({id, name, position, size, color, owner}) {
  return {id, name, asset_id: BOX, owner_id: owner, position, rotation: [0, 0, 0, 1],
    size, color, material: 'plain', state: {}, group_id: ''};
}

function visualPosition(sample, manifest) {
  const [x, y, predictedHeight] = sample.region_position;
  const entries = manifest.tiles || manifest.buildings || [];
  const covering = entries.filter(item => Array.isArray(item.position) && item.position.length === 3
    && Array.isArray(item.bounds) && item.bounds.length === 3
    && item.position.every(finite) && item.bounds.every(finite)
    && x >= item.position[0] - item.bounds[0] / 2 - 1e-6
    && x <= item.position[0] + item.bounds[0] / 2 + 1e-6
    && y >= item.position[1] - item.bounds[1] / 2 - 1e-6
    && y <= item.position[1] + item.bounds[1] / 2 + 1e-6);
  const top = covering.length ? Math.max(...covering.map(item => item.position[2] + item.bounds[2] / 2)) : null;
  // The floating pin is deliberately above the local mesh. Its Z is a
  // display coordinate only; the prediction stays in region_position[2].
  const displayHeight = Math.max(predictedHeight + 2.0, top === null ? predictedHeight + 2.0 : top + 2.0);
  if (displayHeight > 119.0) throw Error(`sample ${sample.id} display marker exceeds the region height limit`);
  return [x, y, Number(displayHeight.toFixed(6))];
}

function expectedObjects(dataset, owner) {
  const n = dataset.normalized;
  const positions = n.samples.map(sample => visualPosition(sample, dataset.manifest));
  const first = positions[0];
  const anchor = makeObject({id: deterministicId(n.source_id, n.batch_id, 'batch'),
    name: `预测批次 · ${n.input_sha256}`, position: first.slice(),
    size: [0.2, 0.2, 0.2], color: '#7B8C99', owner});
  const markers = n.samples.map((sample, i) => makeObject({
    id: deterministicId(n.source_id, n.batch_id, 'sample', sample.id),
    name: markerName(sample), position: positions[i],
    size: [1.5, 1.5, 1.5], color: '#19B9D8', owner}));
  return {anchor, markers};
}

function sameObject(existing, wanted) {
  return Object.keys(wanted).every(key => JSON.stringify(existing[key]) === JSON.stringify(wanted[key]));
}

class AuthorityPeer {
  constructor(url, token) {
    this.url = url; this.token = token; this.results = new Map(); this.state = null;
    this.welcome = null; this.closed = false; this.seq = 0;
  }
  async connect() {
    if (typeof WebSocket !== 'function') throw Error('Node 24 or newer is required for WebSocket');
    this.ws = new WebSocket(this.url);
    this.ws.onerror = () => {};
    this.ws.onclose = event => { this.closed = true; this.closeReason = event.reason; };
    this.ws.onmessage = event => {
      const p = JSON.parse(event.data);
      if (p.type === 'welcome') this.welcome = p;
      if (p.type === 'snapshot') this.state = p.state;
      if (p.type === 'delta' && this.state) {
        for (const key of ['objects', 'groups', 'assets', 'avatars']) {
          for (const id of p.delta.deletes[key]) delete this.state[key][id];
          Object.assign(this.state[key], p.delta.upserts[key]);
        }
        if (p.delta.meta) this.state.meta = p.delta.meta;
      }
      if (p.type === 'result' || p.type === 'agent_result') this.results.set(p.request_id, p);
      if (p.type === 'snapshot' || p.type === 'delta') this.send({type: 'ack', seq: p.seq});
    };
    await this.until(() => this.ws.readyState === WebSocket.OPEN || this.closed, 15000);
    if (this.closed) throw Error(`authority connection refused: ${this.closeReason || 'closed'}`);
    this.send({type: 'hello', token: this.token});
    await this.until(() => (this.welcome && this.state) || this.closed, 15000);
    if (this.closed) throw Error(`authority authentication failed: ${this.closeReason || 'closed'}`);
    return this;
  }
  async until(predicate, timeout) {
    const end = Date.now() + timeout;
    for (;;) {
      const value = predicate();
      if (value) return value;
      if (this.closed) throw Error(`authority connection closed: ${this.closeReason || 'closed'}`);
      if (Date.now() > end) throw Error('authority response timeout');
      await delay(40);
    }
  }
  send(body) { this.ws.send(JSON.stringify({fp_version: FP, ...body})); }
  packet(object) {
    return {fp_version: FP, type: 'command', world_id: this.welcome.world_id,
      region_id: this.welcome.region_id, world_epoch: this.welcome.world_epoch,
      request_id: crypto.randomUUID(), trace_id: crypto.randomUUID(), origin: 'world_model',
      source_seq: ++this.seq, expected_revision: this.state.meta.revision,
      expires_at_ms: Date.now() + 30000, operation: 'CreateObject', payload: {object}};
  }
  async submit(packet) {
    this.send(packet);
    try {
      const result = await this.until(() => this.results.get(packet.request_id), 30000);
      if (result.ok) await this.until(() => this.state.meta.revision >= result.revision, 15000);
      return result;
    } catch (error) {
      // Query the exact request identity before declaring an unknown outcome.
      this.send({type: 'query_result', request_id: packet.request_id});
      try { return await this.until(() => this.results.get(packet.request_id), 5000); }
      catch { throw Error(`outcome unknown for request_id ${packet.request_id}: ${error.message}`); }
    }
  }
  async observe() {
    const request_id = crypto.randomUUID();
    this.send({type: 'agent', request_id, action: 'observe', params: {}});
    return this.until(() => this.results.get(request_id), 15000);
  }
  close() { if (this.ws?.readyState === WebSocket.OPEN) this.ws.close(); }
}

function atomicJson(filename, value) {
  const temp = `${filename}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + '\n');
  // On Windows, a short-lived reader (including antivirus indexing) can hold
  // the destination open and make an otherwise valid atomic replace fail.
  for (let attempt = 0; attempt < 40; attempt++) {
    try { fs.renameSync(temp, filename); return; }
    catch (error) {
      if (!['EPERM', 'EACCES'].includes(error.code) || attempt === 39) throw error;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
}

function openLedger(output, dataset, peer) {
  const filename = path.join(output, 'experiment.json');
  if (fs.existsSync(output) && !fs.existsSync(filename))
    throw Error('output directory exists without experiment.json; use a fresh directory');
  if (!fs.existsSync(output)) fs.mkdirSync(output, {recursive: true});
  let ledger;
  if (fs.existsSync(filename)) {
    ledger = JSON.parse(fs.readFileSync(filename, 'utf8'));
    if (ledger.format !== 'region-lab.world-model-experiment' || ledger.batch_id !== dataset.normalized.batch_id
      || ledger.source_id !== dataset.normalized.source_id
      || ledger.hashes.input_sha256 !== dataset.hashes.input_sha256
      || ledger.hashes.manifest_sha256 !== dataset.hashes.manifest_sha256
      || ledger.world_id !== peer.welcome.world_id || ledger.region_id !== peer.welcome.region_id
      || ledger.world_instance_id !== peer.welcome.world_instance_id)
      throw Error('output directory belongs to another batch or world');
  } else {
    const n = dataset.normalized;
    ledger = {format: 'region-lab.world-model-experiment', version: 1,
      status: 'prepared', batch_id: n.batch_id, source_id: n.source_id,
      model_id: n.model_id, model_version: n.model_version,
      observed_at: n.observed_at, generated_at: n.generated_at, predicted_for: n.predicted_for,
      source_crs: n.source_crs, hashes: dataset.hashes,
      world_id: peer.welcome.world_id, region_id: peer.welcome.region_id,
      world_instance_id: peer.welcome.world_instance_id,
      world_epoch: null, preview_world_epoch: peer.welcome.world_epoch,
      latest_world_epoch: peer.welcome.world_epoch,
      revision_before: peer.state.meta.revision,
      revision_after: peer.state.meta.revision, created_at_ms: Date.now(),
      markers: [], receipts: [], agent_observation: null};
    atomicJson(filename, ledger);
  }
  return {filename, events: path.join(output, 'events.jsonl'), ledger};
}

function record(audit, event) {
  const entry = {at_ms: Date.now(), ...event};
  fs.appendFileSync(audit.events, JSON.stringify(entry) + '\n');
  audit.ledger.updated_at_ms = entry.at_ms;
  atomicJson(audit.filename, audit.ledger);
}

function checkWorld(peer, dataset) {
  const region = peer.state?.meta?.region;
  const m = dataset.manifest;
  if (typeof peer.welcome.world_instance_id !== 'string'
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(peer.welcome.world_instance_id))
    throw Error('authority has no durable world_instance_id');
  if (peer.welcome.role !== 'owner' || peer.welcome.actor_id !== region?.owner_id)
    throw Error('an owner session for this region is required');
  if (region.size?.[0] !== m.region_size || region.size?.[1] !== m.region_size)
    throw Error('running region size differs from scene manifest');
  if (region.name !== m.region_name) throw Error('running region name differs from scene manifest');
  const entries = m.tiles || m.buildings || [];
  if (entries.length) {
    const assets = peer.state.assets;
    const objects = Object.values(peer.state.objects);
    const matched = new Set();
    for (const entry of entries) {
      const name = entry.name || `代尔夫特建筑 ${String(entry.id || '').split('.').at(-1)}`;
      const rotation = entry.rotation || [0, 0, 0, 1];
      if (!SHA.test(entry.sha256) || !Array.isArray(entry.position) || !Array.isArray(entry.bounds)
        || !Array.isArray(rotation) || entry.position.length !== 3 || entry.bounds.length !== 3
        || rotation.length !== 4 || ![...entry.position, ...entry.bounds, ...rotation].every(finite))
        throw Error('scene manifest tile transform is invalid');
      const placed = objects.filter(object => object.name === name && assets[object.asset_id]?.sha256 === entry.sha256
        && Array.isArray(object.position) && object.position.length === 3
        && Array.isArray(object.size) && object.size.length === 3
        && Array.isArray(object.rotation) && object.rotation.length === 4
        && object.position.every((value, i) => close(value, entry.position[i]))
        && object.size.every((value, i) => close(value, entry.bounds[i]))
        && object.rotation.every((value, i) => close(value, rotation[i])));
      if (placed.length !== 1 || matched.has(placed[0]?.id))
        throw Error(`running scene tile differs from manifest: ${name}`);
      matched.add(placed[0].id);
    }
  }
}

function markerMapping(dataset, objects) {
  const n = dataset.normalized;
  return n.samples.map((sample, i) => ({object_id: objects.markers[i].id,
    sample_id: sample.id, source_id: n.source_id, model_id: n.model_id,
    model_version: n.model_version, observed_at: n.observed_at,
    generated_at: n.generated_at, predicted_for: n.predicted_for,
    source_position: sample.source_position, region_position: sample.region_position,
    visual_marker_position: objects.markers[i].position,
    display_offset_m: Number((objects.markers[i].position[2] - sample.region_position[2]).toFixed(6)),
    marker_name: objects.markers[i].name}));
}

function warningReceiptId(audit, markerId) {
  if (audit.ledger.agent_warning_receipt?.marker_object_id === markerId) {
    const id = audit.ledger.agent_warning_receipt.object_id;
    if (typeof id === 'string') return id;
  }
  // Older experiment ledgers may have overwritten agent_task on an idempotent
  // replay. Their append-only event file still contains the completed task.
  if (!fs.existsSync(audit.events)) return null;
  for (const line of fs.readFileSync(audit.events, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.type === 'agent_task_receipt' && entry.marker_object_id === markerId
      && entry.task?.state === 'completed') {
      const id = entry.task.detail?.payload?.id;
      if (typeof id === 'string') return id;
    }
  }
  return null;
}

function warningMatches(object, {id, name, position, owner}) {
  const expected = {id, name, asset_id: BOX, owner_id: owner,
    position, rotation: [0, 0, 0, 1], size: [0.3, 0.3, 1.0],
    color: '#F59E0B', material: 'plain', state: {}, group_id: ''};
  return !!object && Object.keys(expected).every(key =>
    key === 'position' || key === 'size' || key === 'rotation'
      ? Array.isArray(object[key]) && object[key].length === expected[key].length
        && object[key].every((value, i) => finite(value) && close(value, expected[key][i]))
      : JSON.stringify(object[key]) === JSON.stringify(expected[key]));
}

async function agentCheck({url, token, dataset, objects, audit}) {
  const client = await new AgentClient({url, token}).connect();
  try {
    if (client.welcome.role !== 'agent') throw Error('agent token must belong to an agent account');
    const before = await client.agent('observe');
    if (!before.ok) throw Error(`agent observe rejected: ${before.code}`);
    const marker = objects.markers[0];
    if (!before.data.state.objects[marker.id]) throw Error('agent cannot observe the prediction marker');
    const sample = dataset.normalized.samples[0];
    const warningName = `待核查警示桩 · ${dataset.hashes.input_sha256.slice(0, 12)} · ${sample.id}`.slice(0, 80);
    const x = sample.region_position[0] + (sample.region_position[0] + 1.2 < dataset.manifest.region_size - 0.2 ? 1.2 : -1.2);
    const position = [x, sample.region_position[1], marker.position[2]];
    const expected = {name: warningName, position, owner: before.data.state.objects[marker.id].owner_id};
    const trustedId = warningReceiptId(audit, marker.id);
    const report = {marker_object_id: marker.id, marker_sample_id: sample.id,
      before: {request_id: before.request_id, revision: before.data.revision,
        at_ms: before.data.at_ms, marker_visible: true},
      warning_name: warningName, warning_position: position, task: null, after: null};
    const existing = trustedId ? before.data.state.objects[trustedId] : null;
    if (existing) {
      if (!warningMatches(existing, {id: trustedId, ...expected}))
        throw Error(`agent warning object differs from its task receipt: ${trustedId}`);
      report.warning_object_id = existing.id;
      report.task = {state: 'already_present', code: '', object_id: existing.id};
      record(audit, {type: 'agent_task_already_present', marker_object_id: marker.id,
        warning_object_id: existing.id, warning_name: warningName});
    } else {
      if (Object.values(before.data.state.objects).some(o => o.name === warningName))
        throw Error(`agent warning name is occupied without its task receipt: ${warningName}`);
      const accepted = await client.agent('task', {kind: 'create_box', name: warningName,
        position, size: [0.3, 0.3, 1.0], color: '#F59E0B'});
      if (!accepted.ok) throw Error(`agent create_box rejected: ${accepted.code}`);
      const terminal = await client.waitTask(accepted.data.task.task_id);
      report.task = {request_id: accepted.request_id, ...terminal};
      record(audit, {type: 'agent_task_receipt', marker_object_id: marker.id,
        request_id: accepted.request_id, task: terminal});
      if (terminal.state !== 'completed') throw Error(`agent warning task ended ${terminal.state}/${terminal.code}`);
      report.warning_object_id = terminal.detail?.payload?.id;
      if (typeof report.warning_object_id !== 'string') throw Error('agent task receipt has no warning object id');
      audit.ledger.agent_warning_receipt = {marker_object_id: marker.id,
        object_id: report.warning_object_id, request_id: accepted.request_id,
        task_id: accepted.data.task.task_id};
      record(audit, {type: 'agent_warning_bound', ...audit.ledger.agent_warning_receipt});
    }
    const after = await client.agent('observe');
    if (!after.ok) throw Error(`agent post-task observe rejected: ${after.code}`);
    const warning = after.data.state.objects[report.warning_object_id];
    if (!after.data.state.objects[marker.id]
      || !warningMatches(warning, {id: report.warning_object_id, ...expected}))
      throw Error('agent post-task observation is missing or changed the warning');
    report.warning_object_id = warning.id;
    report.after = {request_id: after.request_id, revision: after.data.revision,
      at_ms: after.data.at_ms, marker_visible: true, warning_visible: true,
      warning_object_id: warning.id};
    record(audit, {type: 'agent_observation', marker_object_id: marker.id,
      before: report.before, after: report.after});
    return report;
  } finally { client.close(); }
}

async function runExperiment(options) {
  const dataset = validateInputs(options);
  const peer = await new AuthorityPeer(options.url, options.token).connect();
  let audit;
  try {
    checkWorld(peer, dataset);
    const objects = expectedObjects(dataset, peer.welcome.actor_id);
    audit = openLedger(path.resolve(options.output), dataset, peer);
    const wasComplete = audit.ledger.status === 'complete';
    audit.ledger.markers = markerMapping(dataset, objects);
    audit.ledger.anchor_object_id = objects.anchor.id;
    // world_epoch identifies the first application of this experiment. A
    // repeated read after an authority restart must not rewrite that origin.
    if (!options.dryRun && (audit.ledger.world_epoch === null
      || (audit.ledger.status === 'preview' && audit.ledger.receipts.length === 0)))
      audit.ledger.world_epoch = peer.welcome.world_epoch;
    audit.ledger.latest_world_epoch = peer.welcome.world_epoch;
    audit.ledger.latest_seen_revision = peer.state.meta.revision;
    if (!wasComplete) audit.ledger.status = options.dryRun ? 'preview' : 'applying';
    record(audit, {type: options.dryRun ? 'preview_started' : 'apply_started',
      batch_id: dataset.normalized.batch_id, revision: peer.state.meta.revision,
      world_epoch: peer.welcome.world_epoch});
    const pending = [];
    for (const object of [objects.anchor, ...objects.markers]) {
      const present = peer.state.objects[object.id];
      if (present && !sameObject(present, object))
        throw Error(`batch marker conflict for object ${object.id}`);
      if (present) {
        record(audit, {type: 'already_present', object_id: object.id, revision: peer.state.meta.revision});
      } else pending.push(object);
    }
    if (options.dryRun) {
      audit.ledger.preview = {already_present: objects.markers.length + 1 - pending.length,
        would_create: pending.length, marker_count: objects.markers.length};
      if (!wasComplete) audit.ledger.status = 'preview';
      record(audit, {type: 'preview_complete', ...audit.ledger.preview});
      return audit.ledger;
    }
    for (const object of pending) {
      let committed = false;
      for (let attempt = 0; attempt < 3 && !committed; attempt++) {
        const packet = peer.packet(object);
        record(audit, {type: 'command_prepared', object_id: object.id,
          request_id: packet.request_id, trace_id: packet.trace_id,
          expected_revision: packet.expected_revision, world_epoch: packet.world_epoch});
        const receipt = await peer.submit(packet);
        audit.ledger.receipts.push({object_id: object.id, request_id: packet.request_id,
          trace_id: packet.trace_id, operation: packet.operation,
          expected_revision: packet.expected_revision, result: receipt});
        audit.ledger.latest_seen_revision = peer.state.meta.revision;
        if (!wasComplete) audit.ledger.revision_after = peer.state.meta.revision;
        record(audit, {type: 'command_receipt', object_id: object.id,
          request_id: packet.request_id, trace_id: packet.trace_id,
          result: receipt});
        if (receipt.ok) committed = true;
        else if (receipt.code === 'REVISION_CONFLICT') {
          await peer.until(() => peer.state.meta.revision > packet.expected_revision, 5000);
          const now = peer.state.objects[object.id];
          if (now && sameObject(now, object)) committed = true;
          else if (now) throw Error(`batch marker conflict for object ${object.id}`);
        } else throw Error(`authority rejected ${object.id}: ${receipt.code}`);
      }
      if (!committed) throw Error(`revision conflict persisted for ${object.id}`);
    }
    const observation = await peer.observe();
    audit.ledger.agent_observation = {request_id: observation.request_id, ok: observation.ok,
      code: observation.code, revision: observation.data?.revision,
      at_ms: observation.data?.at_ms,
      marker_count_visible: observation.ok ? objects.markers.filter(o => observation.data.state.objects[o.id]).length : 0};
    if (options.agentToken) {
      audit.ledger.agent_task = await agentCheck({url: options.url, token: options.agentToken,
        dataset, objects, audit});
    }
    audit.ledger.latest_seen_revision = peer.state.meta.revision;
    if (!wasComplete) audit.ledger.revision_after = peer.state.meta.revision;
    audit.ledger.status = 'complete';
    audit.ledger.latest_attempt_status = 'complete';
    record(audit, {type: 'experiment_complete', revision: audit.ledger.revision_after,
      marker_count: objects.markers.length, agent_observation: audit.ledger.agent_observation});
    return audit.ledger;
  } catch (error) {
    if (audit) {
      if (audit.ledger.status !== 'complete') audit.ledger.status = 'failed';
      audit.ledger.latest_attempt_status = 'failed';
      record(audit, {type: 'experiment_failed', error: error.message,
        revision: peer.state?.meta?.revision});
    }
    throw error;
  } finally { peer.close(); }
}

function parseArgs(argv) {
  const args = {};
  for (const arg of argv) {
    if (arg === '--dry-run' || arg === '--preview') { args.dryRun = true; continue; }
    const i = arg.indexOf('=');
    if (!arg.startsWith('--') || i < 3) throw Error(`invalid argument: ${arg}`);
    args[arg.slice(2, i)] = arg.slice(i + 1);
  }
  for (const key of ['observation', 'manifest', 'input', 'url', 'output'])
    if (!args[key]) throw Error(`missing --${key}=...`);
  args.token = args.token || process.env.REGION_LAB_TOKEN;
  if (!args.token) throw Error('missing owner token (--token or REGION_LAB_TOKEN)');
  args.agentToken = args['agent-token'] || process.env.REGION_LAB_AGENT_TOKEN || '';
  const url = new URL(args.url);
  if (!['ws:', 'wss:'].includes(url.protocol)) throw Error('URL must use ws:// or wss://');
  return args;
}

if (require.main === module) {
  let args;
  try { args = parseArgs(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 2; }
  if (args) runExperiment(args)
    .then(result => console.log(JSON.stringify({ok: true, status: result.status,
      batch_id: result.batch_id, markers: result.markers.length,
      revision_before: result.revision_before, revision_after: result.revision_after,
      output: path.resolve(args.output)})))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}

module.exports = {validateInputs, deterministicId, expectedObjects, runExperiment, parseArgs};
