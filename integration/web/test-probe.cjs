// Run against a fresh export; browser binaries and output belong outside the repository.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {chromium, firefox} = require('playwright');
const [rootArg, fixtureArg, outputArg] = process.argv.slice(2);
if (!outputArg) throw Error('Usage: node test-probe.cjs EXPORT_DIRECTORY GLB NEW_REPORT_DIRECTORY');
const root = path.resolve(rootArg), output = path.resolve(outputArg);
fs.mkdirSync(output); // Never reuse a report or a browser profile.
const requests = [];
const server = http.createServer((req, res) => {
  let name;
  try { name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); } catch {res.writeHead(400).end();return;}
  const noHeaders = name.startsWith('/no-headers/');
  if (noHeaders) name = name.slice('/no-headers'.length);
  const file = path.resolve(root, '.' + name);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {res.writeHead(404).end(); return;}
  const ext = path.extname(file);
  if (!noHeaders) { res.setHeader('Cross-Origin-Opener-Policy','same-origin'); res.setHeader('Cross-Origin-Embedder-Policy','require-corp'); }
  res.setHeader('Content-Type', ({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.png':'image/png'})[ext] || 'application/octet-stream');
  res.setHeader('Cache-Control', ext === '.html' ? 'no-cache' : 'public, max-age=3600');
  requests.push({url:req.url,utc:new Date().toISOString()});
  fs.createReadStream(file).pipe(res);
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const address = `http://127.0.0.1:${server.address().port}`;
  const results=[];
  try {
    for (const [engine, launcher] of [['chromium',chromium],['firefox',firefox]]) {
      const browser = await launcher.launch({headless:false});
      try {
        for (const profile of ['jolt-single','jolt-threads','godot-single']) {
          const context = await browser.newContext({viewport:{width:1280,height:800}});
          const page = await context.newPage();
          const consoleLog=[];
          page.on('console',m=>consoleLog.push({type:m.type(),text:m.text()}));
          page.on('pageerror',e=>consoleLog.push({type:'pageerror',text:String(e)}));
          const result={engine,browser_version:browser.version(),profile};
          try {
            await page.goto(`${address}/${profile}/index.html`);
            await page.waitForFunction(()=>window.regionLabProbe, null, {timeout:90000});
            result.initial = await page.evaluate(()=>({probe:window.regionLabProbe,isolated:crossOriginIsolated,sharedArrayBuffer:typeof SharedArrayBuffer!=='undefined',webgl2:!!document.createElement('canvas').getContext('webgl2')}));
            await page.locator('#probe-file').setInputFiles(path.resolve(fixtureArg));
            await page.waitForFunction(()=>window.regionLabPicker, null, {timeout:15000});
            result.file_picker=await page.evaluate(()=>window.regionLabPicker);
            await page.screenshot({path:path.join(output,`${engine}-${profile}.png`)});
            // Godot's IDBFS write-behind requires time before unloading.
            await page.waitForTimeout(3000);
            const before = requests.length;
            await page.reload();
            await page.waitForFunction(()=>window.regionLabProbe, null, {timeout:90000});
            result.reloaded = await page.evaluate(()=>window.regionLabProbe);
            result.reload_network_files = requests.slice(before).map(x=>x.url);
            result.passed = result.initial.probe.passed && result.file_picker.passed && result.reloaded.passed && result.reloaded.previous_snapshot_loaded;
          } catch(e) {result.passed=false;result.error=String(e);await page.screenshot({path:path.join(output,`${engine}-${profile}-failure.png`)}).catch(()=>{});}
          result.console=consoleLog;
          results.push(result);
          fs.writeFileSync(path.join(output,`${engine}-${profile}.json`),JSON.stringify(result,null,2)+'\n');
          await context.close();
        }
        const context=await browser.newContext();const page=await context.newPage();
        await page.goto(`${address}/no-headers/jolt-threads/index.html`);
        await page.waitForTimeout(5000);
        results.push({engine,profile:'threads-without-isolation',...(await page.evaluate(()=>({isolated:crossOriginIsolated,started:!!window.regionLabProbe,message:document.body.innerText}))),expected:'does not start'});
        await context.close();
      } finally {await browser.close();}
    }
  } finally {server.close();}
  const report={utc:new Date().toISOString(),platform:process.platform,node:process.version,fixture_sha256:crypto.createHash('sha256').update(fs.readFileSync(fixtureArg)).digest('hex'),results};
  fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(results.map(({console,...x})=>x),null,2));
  // Unsupported profiles are evidence, but both engines must pass a tested fallback.
  if (!['chromium','firefox'].every(e=>results.some(r=>r.engine===e&&r.passed))) process.exitCode=1;
})().catch(e=>{server.close();console.error(e);process.exitCode=1;});
