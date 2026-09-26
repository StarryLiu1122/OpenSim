/* The real HTTPS asset endpoint must honor RegionStore sessions issued after
 * RegionHost starts, and lose access as soon as a session is revoked. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const https = require('node:https');
const {spawn, spawnSync} = require('node:child_process');

const args = Object.fromEntries(process.argv.slice(2).map(value => {
  const split = value.indexOf('=');
  return [value.slice(0, split), value.slice(split + 1)];
}));
const host = path.resolve(args['--host']);
const store = path.resolve(args['--store']);
const output = path.resolve(args['--output']);
if (fs.existsSync(output)) throw Error('Use a new output directory');
fs.mkdirSync(output, {recursive: true});
const storage = path.join(output, 'storage');
const web = path.join(output, 'web');
fs.mkdirSync(storage); fs.mkdirSync(web);
const report = {suite: 'V6 dynamic asset sessions', passed: false, checks: []};
const reportPath = path.join(output, 'report.json');
function check(value, label) {
  report.checks.push({name: label, passed: Boolean(value)});
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  console.log(`${value ? 'PASS' : 'FAIL'} ${label}`);
  if (!value) throw Error(label);
}
const hostArgs = host.endsWith('.dll') ? ['dotnet', host] : [host];
function invokeHost(parameters) {
  return spawnSync(hostArgs[0], [...hostArgs.slice(1), ...parameters], {encoding: 'utf8', windowsHide: true, timeout: 10000});
}
let requestNumber = 0;
function invokeStore(operation, extra = {}) {
  const id = ++requestNumber;
  const source = path.join(output, `store-${id}-request.json`);
  const target = path.join(output, `store-${id}-response.json`);
  fs.writeFileSync(source, JSON.stringify({operation, root: storage, ...extra}));
  const result = spawnSync(store, [source, target], {encoding: 'utf8', windowsHide: true, timeout: 15000});
  if (result.status !== 0 || !fs.existsSync(target)) throw Error(`RegionStore ${operation} failed: ${result.stderr}`);
  const response = JSON.parse(fs.readFileSync(target, 'utf8'));
  if (!response.ok) throw Error(`RegionStore ${operation}: ${response.error}`);
  return response;
}
function hash(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function request(url, token, certificate) {
  return new Promise((resolve, reject) => {
    const transport = url.startsWith('https:') ? https : http;
    const options = {headers: token ? {Authorization: 'Bearer ' + token} : {}};
    if (certificate) options.ca = certificate;
    const req = transport.get(url, options, response => {
      const bytes = [];
      response.on('data', chunk => bytes.push(chunk));
      response.on('end', () => resolve({status: response.statusCode, headers: response.headers, body: Buffer.concat(bytes)}));
    });
    req.on('error', reject); req.setTimeout(10000, () => req.destroy(Error('HTTP timeout')));
  });
}
async function untilReady(url, child) {
  const deadline = Date.now() + 10000;
  for (;;) {
    if (child.exitCode !== null) throw Error('RegionHost exited before health check');
    try { if ((await request(url)).status === 200) return; } catch { }
    if (Date.now() > deadline) throw Error('RegionHost health timeout');
    await new Promise(resolve => setTimeout(resolve, 50));
  }
}

async function main() {
  const certificateResult = invokeHost(['--certificate', output]);
  check(certificateResult.status === 0, 'local TLS certificate generated');
  const certificate = fs.readFileSync(path.join(output, 'localhost.pem'));
  check(invokeStore('init').schema_version >= 7, 'RegionStore session schema initialized');
  const asset = fs.readFileSync(path.join(__dirname, '..', 'prototype', 'fixtures', 'buildings', 'pioneer-log-cabin', 'pioneer-log-cabin.glb'));
  const digest = hash(asset);
  fs.mkdirSync(path.join(storage, 'objects'));
  fs.writeFileSync(path.join(storage, 'objects', `${digest}.glb`), asset);
  const owner = invokeStore('account_create', {name: 'asset-owner', role: 'owner', now_ms: Date.now()}).account.id;
  const other = invokeStore('account_create', {name: 'asset-other', role: 'editor', now_ms: Date.now()}).account.id;
  const catalog = principals => fs.writeFileSync(path.join(storage, 'asset-catalog.json'), JSON.stringify({[digest]: {principals, bytes: asset.length}}));
  catalog([owner]);
  const port = 24000 + crypto.randomInt(0, 10000);
  const config = {storage, web_root: web, certificate: path.join(output, 'localhost.pfx'), port, http_port: port + 1, https_port: port + 2};
  const configPath = path.join(output, 'host-config.json');
  fs.writeFileSync(configPath, JSON.stringify(config));
  const stdout = fs.openSync(path.join(output, 'host.log'), 'w');
  const child = spawn(hostArgs[0], [...hostArgs.slice(1), configPath], {windowsHide: true, stdio: ['ignore', stdout, stdout]});
  fs.closeSync(stdout);
  try {
    await untilReady(`http://127.0.0.1:${port + 1}/health`, child);
    const url = `https://127.0.0.1:${port + 2}/assets/${digest}.glb`;
    const token = crypto.randomBytes(32).toString('hex');
    const otherToken = crypto.randomBytes(32).toString('hex');
    const expiredToken = crypto.randomBytes(32).toString('hex');
    const get = key => request(url, key, certificate);
    check((await get()).status === 401, 'missing token denied');
    // Issue after the gateway starts: it must discover the new session from SQLite.
    invokeStore('session_issue', {account_id: owner, token_hash: hash(token), now_ms: Date.now(), ttl_ms: 3600000});
    const allowed = await get(token);
    check(allowed.status === 200 && hash(allowed.body) === digest && allowed.headers['cache-control'] === 'private, no-store', 'newly issued account fetches exact content without gateway restart');
    const assetPath = path.join(storage, 'objects', `${digest}.glb`);
    fs.writeFileSync(assetPath, Buffer.concat([asset, Buffer.from([0])]));
    try { check((await get(token)).status === 503, 'content altered behind a known hash is refused'); }
    finally { fs.writeFileSync(assetPath, asset); }
    invokeStore('session_issue', {account_id: other, token_hash: hash(otherToken), now_ms: Date.now(), ttl_ms: 3600000});
    check((await get(otherToken)).status === 404, 'valid session without asset grant cannot fetch known hash');
    catalog([owner, other]);
    check((await get(otherToken)).status === 200, 'new grant becomes effective without gateway restart');
    catalog([owner]);
    check((await get(otherToken)).status === 404, 'revoked asset grant takes effect on next request');
    check((await request(`https://127.0.0.1:${port + 2}/assets/${'0'.repeat(64)}.glb`, token, certificate)).status === 404, 'unknown content hash remains hidden');
    invokeStore('session_revoke', {token_hash: hash(token), now_ms: Date.now()});
    check((await get(token)).status === 401, 'session revocation blocks next asset request');
    const renewed = crypto.randomBytes(32).toString('hex');
    invokeStore('session_issue', {account_id: owner, token_hash: hash(renewed), now_ms: Date.now(), ttl_ms: 3600000});
    check((await get(renewed)).status === 200, 'fresh token restores authorized access');
    invokeStore('account_disable', {account_id: owner, disabled: true, now_ms: Date.now()});
    check((await get(renewed)).status === 401, 'disabled account cannot fetch assets');
    invokeStore('session_issue', {account_id: other, token_hash: hash(expiredToken), now_ms: Date.now() - 70000, ttl_ms: 60000});
    check((await get(expiredToken)).status === 401, 'expired persistent session denied');
    report.passed = true; fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  } finally {
    child.kill();
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
