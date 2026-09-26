/* End-to-end test against a fresh, initialized Region Lab instance seeded
 * with the scene named by --manifest. Starts the real Godot authority and
 * connects to its direct local FP 0.3 WebSocket port. Node 24 only. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {runExperiment, validateInputs} = require('./WorldModelExperiment.cjs');
const {merge} = require('./MergeExpertReviews.cjs');

const args = Object.fromEntries(process.argv.slice(2).map(arg => {
  const i = arg.indexOf('=');
  if (!arg.startsWith('--') || i < 3) throw Error(`invalid argument ${arg}`);
  return [arg.slice(2, i), arg.slice(i + 1)];
}));
for (const key of ['config', 'observation', 'manifest', 'input', 'output'])
  if (!args[key]) throw Error(`missing --${key}=...`);
const output = path.resolve(args.output);
if (fs.existsSync(output)) throw Error('use a new test output directory');
fs.mkdirSync(output, {recursive: true});
const configPath = path.resolve(args.config);
const config = JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, ''));
const original = JSON.parse(fs.readFileSync(args.input, 'utf8'));
const normalized = JSON.parse(fs.readFileSync(args.observation, 'utf8'));
const checks = [];
let server, gateway, client;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, ms = 30000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await predicate();
    if (value) return value;
    if (Date.now() > end) throw Error('test wait timed out');
    await sleep(100);
  }
}
function check(value, name) {
  checks.push({name, passed: !!value});
  console.log(`${value ? 'PASS' : 'FAIL'} ${name}`);
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify({checks, passed: checks.every(c => c.passed)}, null, 2));
  if (!value) throw Error(name);
}
async function rejects(promise, pattern) {
  try { await promise; return false; } catch (error) { return pattern.test(error.message); }
}
async function run() {
  const agent = {id: crypto.randomUUID(), name: 'world-model-agent',
    actor: config.principals[0].actor, role: 'agent', token: crypto.randomBytes(32).toString('hex'),
    expires_at_ms: Date.now() + 3600000};
  config.principals.push(agent);
  fs.writeFileSync(configPath, JSON.stringify(config));
  const ready = path.join(config.storage, 'server-ready.json');
  if (fs.existsSync(ready)) throw Error('test instance already has a server-ready marker');
  let generation = 0;
  async function startAuthority() {
    generation += 1;
    if (fs.existsSync(ready)) fs.unlinkSync(ready);
    const log = fs.openSync(path.join(output, `authority-${generation}.log`), 'w');
    server = spawn(config.godot, ['--headless', '--path', config.project,
      '--log-file', path.join(output, `authority-engine-${generation}.log`),
      'res://network/server.tscn', '--', `--network-config=${configPath}`],
      {windowsHide: true, stdio: ['ignore', log, log]});
    fs.closeSync(log);
    await until(() => fs.existsSync(ready) || server.exitCode !== null, 60000);
  }
  await startAuthority();
  check(server.exitCode === null && fs.existsSync(ready), 'real Godot authority starts');
  const url = `ws://127.0.0.1:${config.port}`;
  const opts = {observation: args.observation, manifest: args.manifest, input: args.input,
    url, token: config.principals[0].token, agentToken: agent.token,
    output: path.join(output, 'experiment')};
  const preview = await runExperiment({...opts, dryRun: true});
  check(preview.status === 'preview' && preview.preview.would_create === 2
    && preview.revision_before === preview.revision_after, 'dry-run previews without world mutation');
  const applied = await runExperiment(opts);
  check(applied.status === 'complete' && applied.revision_after >= preview.revision_before + 3
    && applied.receipts.filter(r => r.result.ok).length === 2, 'anchor and prediction marker commit through durable authority receipts');
  check(applied.world_instance_id === config.world_instance_id,
    'completed experiment binds to its durable instance identity');
  check(applied.markers[0].visual_marker_position[2] > applied.markers[0].region_position[2] + 2
    && applied.markers[0].display_offset_m > 2, 'display pin sits above the mesh while scientific water level is retained');
  check(applied.agent_task?.task?.state === 'completed'
    && applied.agent_task.before.marker_visible && applied.agent_task.after.warning_visible,
    'controlled agent observes the pin and creates a bounded warning post');
  const replay = await runExperiment(opts);
  check(replay.status === 'complete' && replay.revision_after === applied.revision_after
    && replay.agent_task.task.state === 'already_present', 'repeating the same batch creates no objects');
  const laterPreview = await runExperiment({...opts, dryRun: true});
  check(laterPreview.status === 'complete' && laterPreview.revision_after === applied.revision_after
    && JSON.parse(fs.readFileSync(path.join(opts.output, 'experiment.json'))).status === 'complete',
  'preview after completion preserves the completed experiment ledger');
  check(await rejects(runExperiment({...opts, agentToken: config.principals[2].token}),
    /agent token must belong/)
    && JSON.parse(fs.readFileSync(path.join(opts.output, 'experiment.json'))).status === 'complete',
  'failed later agent check does not revoke an already completed experiment');
  const recovered = await runExperiment(opts);
  check(recovered.status === 'complete' && recovered.agent_task.task.state === 'already_present',
    'authorized replay recovers after a failed optional agent check');
  check(await rejects(runExperiment({...opts, output: path.join(output, 'unbound-warning')}),
    /warning name is occupied without its task receipt/),
  'same-named warning in a new audit directory cannot impersonate an agent task receipt');
  const raw2 = structuredClone(original);
  raw2.samples[0].water_surface_height += 1;
  const rawPath = path.join(output, 'changed-input.json');
  const rawBytes = Buffer.from(JSON.stringify(raw2));
  fs.writeFileSync(rawPath, rawBytes);
  const norm2 = structuredClone(normalized);
  norm2.input_sha256 = crypto.createHash('sha256').update(rawBytes).digest('hex');
  norm2.samples[0].source_position[2] += 1;
  norm2.samples[0].region_position[2] += 1;
  const normPath = path.join(output, 'changed-normalized.json');
  fs.writeFileSync(normPath, JSON.stringify(norm2));
  check(await rejects(runExperiment({...opts, observation: normPath, input: rawPath,
    output: path.join(output, 'changed-experiment')}), /batch marker conflict/),
    'same batch identity with changed model input is rejected');
  const bad = structuredClone(norm2); bad.manifest_sha256 = '0'.repeat(64);
  const badPath = path.join(output, 'bad-normalized.json');
  fs.writeFileSync(badPath, JSON.stringify(bad));
  check(await rejects(Promise.resolve().then(() => validateInputs({observation: badPath,
    manifest: args.manifest, input: rawPath})), /manifest_sha256 mismatch/),
    'tampered manifest digest is rejected before network access');
  const wrongBatch = structuredClone(normalized);
  wrongBatch.batch_id = 'other-batch';
  const wrongBatchPath = path.join(output, 'wrong-batch.json');
  fs.writeFileSync(wrongBatchPath, JSON.stringify(wrongBatch));
  check(await rejects(Promise.resolve().then(() => validateInputs({observation: wrongBatchPath,
    manifest: args.manifest, input: args.input})), /batch_id identity mismatch/),
    'normalized batch identity must agree with the hashed source input');
  const wrongScene = JSON.parse(fs.readFileSync(args.manifest, 'utf8'));
  wrongScene.region_size = 256;
  const wrongScenePath = path.join(output, 'wrong-size-manifest.json');
  const wrongSceneBytes = Buffer.from(JSON.stringify(wrongScene));
  fs.writeFileSync(wrongScenePath, wrongSceneBytes);
  const wrongRegionRecord = structuredClone(normalized);
  wrongRegionRecord.manifest_sha256 = crypto.createHash('sha256').update(wrongSceneBytes).digest('hex');
  const wrongRegionPath = path.join(output, 'wrong-size-normalized.json');
  fs.writeFileSync(wrongRegionPath, JSON.stringify(wrongRegionRecord));
  check(await rejects(runExperiment({...opts, manifest: wrongScenePath,
    observation: wrongRegionPath, output: path.join(output, 'wrong-size-experiment')}),
    /running region size/), 'running region size must match the manifest');
  const shiftedScene = JSON.parse(fs.readFileSync(args.manifest, 'utf8'));
  shiftedScene.tiles[0].position[0] += 5;
  const shiftedScenePath = path.join(output, 'shifted-tile-manifest.json');
  const shiftedSceneBytes = Buffer.from(JSON.stringify(shiftedScene));
  fs.writeFileSync(shiftedScenePath, shiftedSceneBytes);
  const shiftedRecord = structuredClone(normalized);
  shiftedRecord.manifest_sha256 = crypto.createHash('sha256').update(shiftedSceneBytes).digest('hex');
  const shiftedRecordPath = path.join(output, 'shifted-tile-normalized.json');
  fs.writeFileSync(shiftedRecordPath, JSON.stringify(shiftedRecord));
  check(await rejects(runExperiment({...opts, manifest: shiftedScenePath,
    observation: shiftedRecordPath, output: path.join(output, 'shifted-tile-experiment')}),
    /tile differs from manifest/), 'moved scene tile is rejected before marker injection');
  check(await rejects(runExperiment({...opts, token: config.principals[2].token,
    output: path.join(output, 'observer-experiment')}), /owner session/),
    'observer cannot apply model markers');
  if (args.visual === 'true') {
    const gatewayLog = fs.openSync(path.join(output, 'gateway.log'), 'w');
    gateway = spawn(config.host_executable, [configPath],
      {windowsHide: true, stdio: ['ignore', gatewayLog, gatewayLog]});
    fs.closeSync(gatewayLog);
    await until(async () => {
      if (gateway.exitCode !== null) return true;
      try { return (await (await fetch(`http://127.0.0.1:${config.http_port}/health`)).json()).ok; }
      catch { return false; }
    }, 30000);
    check(gateway.exitCode === null, 'local HTTPS asset gateway starts for visual check');
    const clientDir = path.join(output, 'client');
    fs.mkdirSync(clientDir);
    const clientLog = fs.openSync(path.join(clientDir, 'process.log'), 'w');
    client = spawn(config.godot, ['--path', config.project,
      '--log-file', path.join(clientDir, 'engine.log'), 'res://network/client.tscn', '--',
      `--network-config=${configPath}`, '--profile=editor-a', `--network-testdir=${clientDir}`],
    {windowsHide: true, stdio: ['ignore', clientLog, clientLog]});
    fs.closeSync(clientLog);
    const observationPath = path.join(clientDir, 'observation.json');
    const observation = await until(() => {
      try {
        const value = JSON.parse(fs.readFileSync(observationPath, 'utf8'));
        return value.interactive && value.assets_ready ? value : false;
      } catch { return false; }
    }, 45000);
    check(observation.review_marker_count === 1, 'desktop client recognizes the model prediction marker');
    const screenshot = path.join(clientDir, 'client.png');
    const control = path.join(clientDir, 'control.json');
    fs.writeFileSync(control, JSON.stringify({serial: 1,
      actions: [{type: 'dismiss_help'}, {type: 'screenshot'}]}));
    await until(() => fs.existsSync(screenshot), 15000);
    check(fs.statSync(screenshot).size > 10000, 'desktop client renders a prediction scene screenshot');
    fs.copyFileSync(screenshot, path.join(clientDir, 'scene.png'));
    fs.unlinkSync(screenshot);
    fs.writeFileSync(control, JSON.stringify({serial: 2,
      actions: [{type: 'test_review_open'}, {type: 'test_review_label', note: '预测位置需现场核查'}]}));
    const reviewed = await until(() => {
      try {
        const value = JSON.parse(fs.readFileSync(observationPath, 'utf8'));
        return value.review_record_count === 1 ? value : false;
      } catch { return false; }
    }, 15000);
    check(reviewed.review_selected_id === applied.markers[0].object_id,
      'desktop review selects the committed prediction marker');
    const reviewFile = JSON.parse(fs.readFileSync(path.join(clientDir, 'expert-reviews.json'), 'utf8'));
    const review = reviewFile.records[0];
    check(reviewFile.format === 'region-lab.expert-review' && reviewFile.records.length === 1
      && review.marker_object_id === applied.markers[0].object_id
      && review.region_id === applied.region_id
      && review.world_instance_id === applied.world_instance_id
      && review.world_epoch === applied.world_epoch
      && review.world_revision >= applied.revision_after
      && JSON.stringify(review.marker_position) === JSON.stringify(applied.markers[0].visual_marker_position),
    'expert review refers to the same world, revision and visual marker');
    fs.writeFileSync(control, JSON.stringify({serial: 3, actions: [{type: 'screenshot'}]}));
    await until(() => fs.existsSync(screenshot), 15000);
    fs.copyFileSync(screenshot, path.join(clientDir, 'review.png'));
    check(fs.statSync(path.join(clientDir, 'review.png')).size > 10000,
      'desktop review page screenshot was rendered');
  }
  server.kill();
  await until(() => server.exitCode !== null || server.signalCode !== null, 10000);
  await startAuthority();
  check(server.exitCode === null && fs.existsSync(ready), 'authority restarts from the committed world');
  const afterRestart = await runExperiment(opts);
  check(afterRestart.world_instance_id === applied.world_instance_id
    && afterRestart.world_epoch === applied.world_epoch
    && afterRestart.latest_world_epoch !== applied.world_epoch
    && afterRestart.revision_after === applied.revision_after,
    'replay after restart preserves original experiment epoch without mutating the world');
  if (args.visual === 'true') {
    const reviewPath = path.join(output, 'client', 'expert-reviews.json');
    const laterReview = JSON.parse(fs.readFileSync(reviewPath, 'utf8'));
    laterReview.records[0].world_epoch = afterRestart.latest_world_epoch;
    const laterPath = path.join(output, 'review-after-restart.json');
    fs.writeFileSync(laterPath, JSON.stringify(laterReview));
    const comparison = merge(path.join(output, 'experiment', 'experiment.json'), laterPath);
    check(comparison.reviews.length === 1 && !comparison.reviews[0].epoch_match
      && comparison.cautions.length === 2,
    'review merge flags a later authority epoch against the original experiment');
  }
  const logs = [1, 2].map(i => fs.readFileSync(path.join(output, `authority-engine-${i}.log`), 'utf8'));
  check(logs.every(logText => !/SCRIPT ERROR|Parse Error/i.test(logText)),
    'authority has no GDScript errors before or after restart');
}

run().catch(error => {console.error(error); process.exitCode = 1;})
  .finally(async () => {
    for (const child of [client, gateway]) {
      if (child && child.exitCode === null) {
        child.kill();
        await until(() => child.exitCode !== null || child.signalCode !== null, 10000).catch(() => {});
      }
    }
    if (server && server.exitCode === null) {
      server.kill();
      await until(() => server.exitCode !== null || server.signalCode !== null, 10000).catch(() => {});
    }
  });
