// Playwright 1.62.1. Five new browser processes/profiles per engine; local HTTPS.
const fs=require('fs'),path=require('path'),{spawn,execFileSync}=require('child_process');
const {chromium,firefox}=require('playwright');
const args=Object.fromEntries(process.argv.slice(2).map(s=>{const i=s.indexOf('=');return[s.slice(0,i),s.slice(i+1)]}));
const configPath=path.resolve(args['--config']),output=path.resolve(args['--output']);
fs.mkdirSync(output,{recursive:false});
const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));
const checks=[],samples=[],children=[],versions={},consoles=[];
const url=`https://127.0.0.1:${config.https_port}`;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const read=p=>{try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}};
const write=(p,v)=>{fs.writeFileSync(p+'.tmp',JSON.stringify(v));fs.renameSync(p+'.tmp',p)};
function report(){write(path.join(output,'report.json'),{suite:'V5 Web desktop interoperability and cold load',passed:checks.length>0&&checks.every(x=>x.passed),network:{aggregate_mbps:config.test_mbps,scope:'gateway static response body; local loopback latency, no WAN RTT emulation',cold:'new browser process and temporary profile each run; OS file and driver caches not cleared'},versions,checks,samples,console:consoles})}
function check(value,name,detail){checks.push({name,passed:!!value,...(detail===undefined?{}:{detail})});console.log(`${value?'PASS':'FAIL'} ${name}`);report();if(!value)throw Error(name)}
async function until(fn,timeout=20000){const end=Date.now()+timeout;while(Date.now()<end){const value=fn();if(value)return value;await delay(50)}throw Error('Timeout '+fn.toString().slice(0,150))}
function launch(exe,argv,name){const fd=fs.openSync(path.join(output,name+'.log'),'w');const child=spawn(exe,argv,{windowsHide:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);children.push(child);return child}
async function stop(p){if(p?.exitCode===null){p.kill();await until(()=>p.exitCode!==null||p.signalCode!==null,10000)}}
async function action(page,value){await page.evaluate(a=>window.regionLabActions.push(a),value)}
async function observation(page){return page.evaluate(()=>window.regionLabObservation)}
async function interactive(page){await page.waitForFunction(()=>window.regionLabObservation?.interactive,null,{timeout:30000})}
async function login(page){await page.waitForFunction(()=>window.regionLabBooted,null,{timeout:90000});await action(page,{type:'login',url,token:config.principals[0].token});await interactive(page)}
async function command(page,operation,payload,label){await interactive(page);await action(page,{type:'command',operation,payload,label});await page.waitForFunction(label=>{const o=window.regionLabObservation,r=o?.results[o.commands[label]];return r&&(!r.ok||o.state.meta.revision>=r.revision)},label,{timeout:20000});return page.evaluate(label=>{const o=window.regionLabObservation;return o.results[o.commands[label]]},label)}
async function metrics(page,engine,run,kind){return {...await page.evaluate(()=>({elapsed_ms:performance.now(),viewport:{css_width:innerWidth,css_height:innerHeight,dpr:devicePixelRatio,canvas_width:document.querySelector("canvas").width,canvas_height:document.querySelector("canvas").height},renderer:(()=>{const gl=document.querySelector("canvas").getContext("webgl2");const ext=gl?.getExtension("WEBGL_debug_renderer_info");return ext?gl.getParameter(ext.UNMASKED_RENDERER_WEBGL):"unavailable"})(),fps:window.regionLabObservation.fps,interactive_ms:window.regionLabObservation.first_interactive_ms,snapshot_ms:window.regionLabObservation.first_snapshot_ms,profile:window.regionLabObservation.startup_profile,nodes:window.regionLabObservation.nodes,asset_ready:window.regionLabObservation.assets_ready,bytes_received:window.regionLabObservation.bytes_received,isolated:crossOriginIsolated,resources:performance.getEntriesByType('resource').map(r=>({name:new URL(r.name).pathname,transfer:r.transferSize,encoded:r.encodedBodySize,decoded:r.decodedBodySize,duration_ms:r.duration}))})),engine,run,kind}}
async function functional(page,context,engine,browserPid){
 const nativeDir=path.join(output,engine+'-desktop');fs.mkdirSync(nativeDir);let serial=0;
 const desktop=launch(config.godot,['--path',config.project,'--max-fps','60','--log-file',path.join(nativeDir,'engine.log'),'res://network/client.tscn','--','--network-config='+configPath,'--profile=editor-b','--network-testdir='+nativeDir],engine+'-desktop');
 let lastNative;const native=()=>lastNative=read(path.join(nativeDir,'observation.json'))||lastNative;
 const nativeAction=(...actions)=>write(path.join(nativeDir,'control.json'),{serial:++serial,actions});
 await until(()=>native()?.interactive);await page.waitForFunction(()=>window.regionLabObservation.remote_avatars===1);
 let state=(await observation(page)).state;
 const object=Object.values(state.objects).find(x=>!x.group_id&&x.asset_id==='22222222-2222-4222-8222-222222222222');
 check((await command(page,'UpdateObject',{id:object.id,patch:{name:engine+' browser update'}},'edit')).ok,engine+' browser edit committed');
 await until(()=>native().state.objects[object.id].name===engine+' browser update');check(true,engine+' edit visible in real desktop');
 const door=Object.values(state.objects).find(x=>state.assets[x.asset_id].kind==='door'),lamp=Object.values(state.objects).find(x=>state.assets[x.asset_id].kind==='lamp');
 nativeAction({type:'command',operation:'SetObjectState',payload:{id:door.id,active:!door.state.active},label:'door'});
 await page.waitForFunction(({id,value})=>window.regionLabObservation.state.objects[id].state.active===value,{id:door.id,value:!door.state.active});check(true,engine+' desktop door state reaches browser');
 check((await command(page,'SetObjectState',{id:lamp.id,active:!lamp.state.active},'lamp')).ok,engine+' browser lamp state committed');
 await until(()=>native().state.objects[lamp.id].state.active===!lamp.state.active);check(true,engine+' browser lamp state reaches desktop');
 const revision=(await observation(page)).state.meta.revision;
 await page.locator('#region-file').dispatchEvent('cancel');await page.waitForFunction(()=>window.regionLabObservation.message.includes('取消'));
 check((await observation(page)).state.meta.revision===revision,engine+' file picker cancel leaves world unchanged');
 await page.locator('#region-file').setInputFiles(path.resolve(args['--fixture']));await page.waitForFunction(()=>window.regionLabObservation.message.includes('已读取 GLB'));
 check((await observation(page)).state.meta.revision===revision,engine+' file selection stages provenance before upload');
 const bytes=fs.readFileSync(args['--fixture']).toString('base64');
 const imported=await command(page,'UploadAsset',{bytes,name:'Browser bench',license:'CC0-1.0',attribution:'Region Lab original validation asset'},'upload');
 check(imported.ok,engine+' selected GLB validated and stored by authority');
 const meshObject=structuredClone(object);meshObject.id=require('crypto').randomUUID();meshObject.asset_id=imported.payload.id;meshObject.material='plain';meshObject.name=engine+' imported bench';meshObject.position=[137,120,1];meshObject.size=[2.5,1,1];
 check((await command(page,'CreateObject',{object:meshObject},'mesh')).ok,engine+' imported asset instantiated');await interactive(page);await until(()=>native().state.objects[meshObject.id]);
 const download=page.waitForEvent('download');await action(page,{type:'download'});const file=await download;await file.saveAs(path.join(output,engine+'-observation.json'));
 const exported=read(path.join(output,engine+'-observation.json'));check(exported.format==='region-lab.observation'&&!JSON.stringify(exported).includes(config.principals[0].token),engine+' observation download contains no session token');
 // Pointer lock must originate in a real click, not an automation-only API.
 await page.bringToFront();await page.mouse.click(162,218);
 await page.waitForFunction(()=>!!document.pointerLockElement,null,{timeout:5000}).catch(()=>{});
 const locked=await page.evaluate(()=>!!document.pointerLockElement);
 if(locked)await page.keyboard.press('Escape');
 check(locked,engine+' pointer lock entered by a user gesture and released with Escape',await page.evaluate(()=>({focus:document.hasFocus(),hidden:document.hidden})));
 await action(page,{type:'interest',centre:[10,10,0],radius:8});await page.waitForFunction(()=>window.regionLabObservation.nodes<3&&window.regionLabObservation.asset_cache_count===0);
 check(true,engine+' AOI exit frees Web nodes and mesh cache');
 await action(page,{type:'interest',centre:[128,140,2],radius:96});await page.waitForFunction(()=>window.regionLabObservation.nodes>40&&window.regionLabObservation.interactive&&window.regionLabObservation.assets_ready);
 check((await observation(page)).assets_ready,engine+' AOI reentry rebuilds validated collision assets');
 // Network interruption after eviction must not falsely enable collision-free walking.
 await action(page,{type:'interest',centre:[10,10,0],radius:8});await page.waitForFunction(()=>window.regionLabObservation.asset_cache_count===0);
 await context.route('**/assets/*.glb',route=>route.abort('connectionfailed'));
 await action(page,{type:'interest',centre:[128,140,2],radius:96});await page.waitForFunction(()=>window.regionLabObservation.asset_error.length>0);
 check(!(await observation(page)).interactive,engine+' interrupted asset request blocks readiness');
 await context.unroute('**/assets/*.glb');await action(page,{type:'retry_assets'});await interactive(page);check(true,engine+' interrupted download recovers with authenticated retry');
 await action(page,{type:'interest',centre:[10,10,0],radius:8});await page.waitForFunction(()=>window.regionLabObservation.asset_cache_count===0);
 await context.route('**/assets/*.glb',route=>{const bytes=fs.readFileSync(path.join(config.storage,'objects',path.basename(new URL(route.request().url()).pathname)));bytes[0]^=1;return route.fulfill({status:200,contentType:'model/gltf-binary',body:bytes})});
 await action(page,{type:'interest',centre:[128,140,2],radius:96});await page.waitForFunction(()=>window.regionLabObservation.asset_error.includes('200'));
 check(!(await observation(page)).interactive,engine+' client rejects HTTP 200 body with wrong exact SHA256');
 await context.unroute('**/assets/*.glb');await action(page,{type:'retry_assets'});await interactive(page);check(true,engine+' corrected content restores collision readiness');
 // Keep the authority and desktop active while the browser tab is hidden.
 const changeWindow=state=>execFileSync('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'Set-TestBrowserWindow.ps1'),'-BrowserProcessId',String(browserPid),'-State',state],{windowsHide:true});
 // Playwright forces page visibility/focus in both patched browser engines.
 // Verify the actual native window is minimized, and pause its frame/timer clock
 // explicitly to test authority independence without pretending document.hidden.
 await page.clock.install();await page.clock.pauseAt(new Date());changeWindow('Minimize');
 const beforePause=(await observation(page)).seq;
 check(true,engine+' test browser window minimized and frame clock paused',{document_hidden:await page.evaluate(()=>document.hidden),clock:'Playwright deterministic frame/timer pause; native window IsIconic verified'});
 nativeAction({type:'command',operation:'UpdateObject',payload:{id:object.id,patch:{name:engine+' background update'}},label:'background'});
 await until(()=>native()?.state.objects[object.id].name===engine+' background update');check(true,engine+' authority continues while browser is backgrounded');
 check((await observation(page)).seq===beforePause,engine+' suspended frame loop did not apply the newer world');
 changeWindow('Restore');await page.clock.resume();await page.bringToFront();await action(page,{type:'resync'});await page.waitForFunction(name=>window.regionLabObservation.state.objects[Object.keys(window.regionLabObservation.state.objects).find(id=>window.regionLabObservation.state.objects[id].name===name)],engine+' background update');
 check(true,engine+' resumed browser converges on current authority state');
 await page.screenshot({path:path.join(output,engine+'-client.png')});
 await action(page,{type:'disconnect'});await page.waitForFunction(()=>!window.regionLabObservation.online);
 await action(page,{type:'command',operation:'UpdateObject',payload:{id:object.id,patch:{name:'offline'}},label:'offline'});await delay(300);
 check(!(await observation(page)).commands.offline,engine+' disconnected edit cannot report success');
 await page.reload({waitUntil:'domcontentloaded'});await page.waitForFunction(()=>window.regionLabObservation);
 check(!(await observation(page)).online,engine+' refresh clears session and requires login');
 check(await page.evaluate(token=>!JSON.stringify({...localStorage,...sessionStorage}).includes(token),config.principals[0].token),engine+' session token never stored in browser persistent storage');
 await login(page);check((await observation(page)).state.objects[object.id].name===engine+' background update',engine+' relogin restores authoritative state after refresh');
 nativeAction({type:'screenshot'});await until(()=>fs.existsSync(path.join(nativeDir,'client.png')));
 check((await command(page,'DeleteObject',{id:meshObject.id},'cleanup-object')).ok,engine+' removes temporary imported object after roundtrip');
 await interactive(page);
 check((await command(page,'RemoveAsset',{id:imported.payload.id},'cleanup-asset')).ok,engine+' removes unused temporary asset for the next cold-load sample');
 await stop(desktop);
}
async function run(){
 const manifest=read(path.join(config.web_root,'..','export-manifest.json'));
 if(!manifest)throw Error('A completed export manifest is required before launching browsers');
 for(const entry of manifest.files){const bytes=fs.readFileSync(path.join(config.web_root,entry.path));if(bytes.length!==entry.bytes||require('crypto').createHash('sha256').update(bytes).digest('hex')!==entry.sha256)throw Error('Export file differs from manifest: '+entry.path)}
 config.test_mbps=50;write(configPath,config);
 const ready=path.join(config.storage,'server-ready.json');if(fs.existsSync(ready))fs.unlinkSync(ready);
 launch(config.godot,['--headless','--path',config.project,'--log-file',path.join(output,'authority.engine.log'),'res://network/server.tscn','--','--network-config='+configPath],'authority');await until(()=>read(ready),45000);
 launch(config.host_executable,[configPath],'gateway');await delay(800);
 for(const [engine,launcher] of [['chromium',chromium],['firefox',firefox]].filter(([name])=>!args['--engines']||args['--engines'].split(',').includes(name))){
  for(let run=1;run<=Number(args['--runs']||5);run++){
   const browserServer=await launcher.launchServer({headless:false});const browser=await launcher.connect(browserServer.wsEndpoint());versions[engine]=browser.version();let currentPage;
   try{
    const context=await browser.newContext({ignoreHTTPSErrors:true,viewport:{width:1440,height:960},deviceScaleFactor:1,acceptDownloads:true});const page=await context.newPage();currentPage=page;
    const logs=[];page.on('console',m=>{if(['error','warning'].includes(m.type()))logs.push({type:m.type(),text:m.text()})});page.on('pageerror',e=>logs.push({type:'pageerror',text:String(e)}));
    await page.goto(url,{waitUntil:'domcontentloaded'});await login(page);
    const cold=await metrics(page,engine,run,'cold');samples.push(cold);console.log(`MEASURE ${engine} cold ${run}: ${cold.elapsed_ms.toFixed(1)} ms`);report();
    check(cold.asset_ready&&cold.nodes>=44&&cold.isolated,`${engine} cold ${run} is interactive with complete collisions and isolation headers`);
    if(run===1){
     await page.screenshot({path:path.join(output,engine+'-cold.png')});
     await page.reload({waitUntil:'domcontentloaded'});await login(page);samples.push(await metrics(page,engine,run,'hot'));report();
     if(args['--functional']!=='false')await functional(page,context,engine,browserServer.process().pid);
    }
    consoles.push({engine,run,logs});
    check(!logs.some(x=>x.type==='pageerror'||/SCRIPT ERROR|Parse Error|Failed to load script/.test(x.text)),`${engine} run ${run} has no script failures`);
    await context.close();
   }catch(error){if(currentPage){await currentPage.screenshot({path:path.join(output,engine+'-failure.png'),timeout:5000}).catch(()=>{});const o=await observation(currentPage).catch(()=>null);if(o)write(path.join(output,engine+'-failure-observation.json'),o)}throw error}finally{await browser.close();await browserServer.close()}
  }
 }
 const cold=samples.filter(s=>s.kind==='cold');
 check(cold.length>=10,'at least five independent cold browser profiles for each engine');
 check(cold.every(s=>s.elapsed_ms<=10000),'every measured 50 Mbps cold start reaches interactive state within ten seconds',{maximum_ms:Math.max(...cold.map(s=>s.elapsed_ms))});
}
run().catch(error=>{checks.push({name:'suite completion',passed:false,error:error.stack});console.error(error);process.exitCode=1}).finally(async()=>{for(const child of children.reverse())await stop(child).catch(()=>{});report()});
