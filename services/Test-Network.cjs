/* Real authority, SQLite, two native clients, TLS assets and failure recovery.
 * Node 24 built-ins only. Use a newly initialized disposable instance. */
const fs = require('fs'), path = require('path'), crypto = require('crypto'), https = require('https');
const {spawn} = require('child_process');
const args = Object.fromEntries(process.argv.slice(2).map(s => { const i=s.indexOf('='); return [s.slice(0,i),s.slice(i+1)]; }));
const configPath=path.resolve(args['--config']), output=path.resolve(args['--output']);
if (fs.existsSync(output)) throw Error('Use a new output directory');
fs.mkdirSync(output,{recursive:true});
const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));
const initialConfig=structuredClone(config), children=[], checks=[], timings=[];
let server, gateway, generation=0;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const read=p=>{try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}};
const write=(p,v)=>{fs.writeFileSync(p+'.tmp',JSON.stringify(v));fs.renameSync(p+'.tmp',p)};
const report=()=>write(path.join(output,'report.json'),{suite:'V5 real network',passed:checks.length>0&&checks.every(x=>x.passed),checks,timings});
function check(value,name,detail){checks.push({name,passed:!!value,...(detail===undefined?{}:{detail})});console.log(`${value?'PASS':'FAIL'} ${name}`);report();if(!value)throw Error(name)}
async function until(fn,timeout=15000){const end=Date.now()+timeout;for(;;){const value=fn();if(value)return value;if(Date.now()>end)throw Error('Timed out: '+fn.toString().slice(0,180));await delay(40)}}
function launch(exe,argv,name,env={}){const fd=fs.openSync(path.join(output,name+'.log'),'w');const child=spawn(exe,argv,{windowsHide:true,stdio:['ignore',fd,fd],env:{...process.env,...env}});fs.closeSync(fd);children.push(child);return child}
async function stop(child){if(child&&child.exitCode===null){child.kill();await until(()=>child.exitCode!==null||child.signalCode!==null,10000)}}
async function startServer(){
  write(configPath,config);const ready=path.join(config.storage,'server-ready.json');if(fs.existsSync(ready))fs.unlinkSync(ready);
  generation++;server=launch(config.godot,['--headless','--path',config.project,'--log-file',path.join(output,`authority-${generation}.engine.log`),'res://network/server.tscn','--','--network-config='+configPath],`authority-${generation}`,{REGIONSTORE_TEST_FAULTS:'1'});
  return until(()=>read(ready),45000);
}
async function restart(){await stop(server);return startServer()}
class Peer{
 constructor(index){this.principal=config.principals[index];this.seq=0;this.messages=[];this.state=null;this.results={};this.closed=false;this.stream=0;this.gaps=0;this.inputSeq=0;}
 async connect(token=this.principal.token,url=`ws://127.0.0.1:${config.http_port}/ws`){
  this.ws=new WebSocket(url);this.ws.onerror=()=>{};this.ws.onclose=e=>{this.closed=true;this.closeCode=e.code};
  this.ws.onmessage=e=>{const p=JSON.parse(e.data);this.messages.push(p);if(this.messages.length>300)this.messages.shift();
   if(p.type==='welcome')this.welcome=p;
   if(p.type==='snapshot'){this.state=p.state;this.stream=p.seq;this.tick=p.tick;}
   if(p.type==='delta'){if(p.seq!==this.stream+1)this.gaps++;this.stream=p.seq;this.tick=p.tick;for(const k of ['objects','groups','assets','avatars']){for(const id of p.delta.deletes[k])delete this.state[k][id];Object.assign(this.state[k],p.delta.upserts[k]);}if(p.delta.meta)this.state.meta=p.delta.meta;}
   if(p.type==='result'||p.type==='permit_result')this.results[p.request_id]=p;
   if(p.type==='snapshot'||p.type==='delta')this.send({type:'ack',seq:p.seq});
  };
  await until(()=>this.ws.readyState===WebSocket.OPEN||this.closed);if(!this.closed)this.send({type:'hello',token});return this;
 }
 send(value){this.ws.send(JSON.stringify({fp_version:'0.3',...value}))}
 async ready(){await until(()=>this.state);return this}
 packet(operation,payload,extra={}){return {fp_version:'0.3',type:'command',world_id:this.welcome.world_id,region_id:this.welcome.region_id,world_epoch:this.welcome.world_epoch,request_id:crypto.randomUUID(),trace_id:crypto.randomUUID(),origin:'test',source_seq:++this.seq,expected_revision:this.state.meta.revision,expires_at_ms:Date.now()+30000,operation,payload,...extra}}
 async submit(packet){const started=performance.now();this.send(packet);const result=await until(()=>this.results[packet.request_id]);timings.push({operation:packet.operation,ok:result.ok,milliseconds:Math.round((performance.now()-started)*100)/100});if(result.ok)await until(()=>this.state.meta.revision>=result.revision);return result}
 async command(op,payload,extra){return this.submit(this.packet(op,payload,extra))}
 async permit(action,params={}){const request_id=crypto.randomUUID();this.send({type:'permit',request_id,action,params});return until(()=>this.results[request_id])}
 input(axis,jump=false){this.send({type:'input',sequence:++this.inputSeq,axis,yaw:0,jump})}
 close(){this.ws.close()}
}
function assetRequest(hash,token){return new Promise((resolve,reject)=>{const request=https.get(`https://127.0.0.1:${config.https_port}/assets/${hash}.glb`,{ca:fs.readFileSync(path.join(path.dirname(configPath),'localhost.pem')),headers:token?{Authorization:'Bearer '+token}:{}},r=>{const chunks=[];r.on('data',c=>chunks.push(c));r.on('end',()=>resolve({status:r.statusCode,body:Buffer.concat(chunks),headers:r.headers}));});request.on('error',reject);request.setTimeout(10000,()=>request.destroy(Error('timeout')));})}
class Native{
 constructor(profile,render=false){this.directory=path.join(output,profile);fs.mkdirSync(this.directory);this.serial=0;
  this.process=launch(config.godot,[...(render?[]:['--headless']),'--path',config.project,'--max-fps','60','--log-file',path.join(this.directory,'engine.log'),'res://network/client.tscn','--','--network-config='+configPath,'--profile='+profile,'--network-testdir='+this.directory],'client-'+profile);
 }
 get value(){return this.lastObservation=read(path.join(this.directory,'observation.json'))||this.lastObservation}
 action(...actions){write(path.join(this.directory,'control.json'),{serial:++this.serial,actions})}
 async ready(){return until(()=>this.value?.interactive,20000)}
 async command(operation,payload,label){this.action({type:'command',operation,payload,label});return until(()=>{const o=this.value;return o?.results[o.commands[label]]})}
}
async function run(){
 config.principals.push({...structuredClone(config.principals[2]),id:crypto.randomUUID(),token:crypto.randomBytes(32).toString('hex'),expires_at_ms:Date.now()-1,name:'expired'});
 const boot=await startServer();
 gateway=launch(config.host_executable,[configPath],'gateway');await delay(500);
 let a=await (await new Peer(0).connect()).ready(),b=await (await new Peer(1).connect()).ready();
 check(a.state.meta.region.id===boot.region_id||a.state.meta.region.id==='33333333-3333-4333-8333-333333333333','authority loaded persistent region');
 check(Object.keys(a.state.objects).length===44&&Object.keys(a.state.groups).length===1,'both clients receive building and fifteen-part group');
 await until(()=>Object.keys(a.state.avatars).length===2&&Object.keys(b.state.avatars).length===2);
 check(a.welcome.principal_id!==b.welcome.principal_id&&a.welcome.actor_id===b.welcome.actor_id,'distinct authenticated principals share the explicit editor grant');
 let invalid=await new Peer(0).connect('invalid');await until(()=>invalid.closed);check(!invalid.state&&!invalid.welcome,'invalid token receives no private state');
 let expired=await new Peer(4).connect();await until(()=>expired.closed);check(!expired.state,'expired token rejected');
 let observer=await (await new Peer(2).connect()).ready();
 const loose=Object.values(a.state.objects).find(x=>!x.group_id&&x.asset_id==='22222222-2222-4222-8222-222222222222');
 check((await observer.command('UpdateObject',{id:loose.id,patch:{name:'forbidden'}})).code==='PERMISSION_DENIED','observer cannot mutate');observer.close();
 let guest=await (await new Peer(3).connect()).ready();
 check(!(await guest.command('UpdateObject',{id:loose.id,patch:{name:'forbidden'}})).ok,'different actor cannot edit another owner');guest.close();
 check((await a.command('LoadRegion',{})).code==='UNSUPPORTED_OPERATION','client cannot replace the authoritative world');
 const forged=a.packet('UpdateObject',{id:loose.id,patch:{name:'forged'}},{actor_id:a.welcome.actor_id});a.send(forged);await until(()=>a.messages.some(p=>p.code==='INVALID_COMMAND'));check(a.state.objects[loose.id].name!=='forged','forged actor field rejected');
 let create=structuredClone(loose);create.id=crypto.randomUUID();create.name='Persistent V5 test object';create.position=[134,120,1];create.size=[1,1,1];
 const wrongOwner={...create,owner_id:crypto.randomUUID()};check(!(await a.command('CreateObject',{object:wrongOwner})).ok,'forged object owner cannot authorize creation');
 const created=await a.command('CreateObject',{object:create});check(created.ok,'world mutation commits before success');await until(()=>b.state.objects[create.id]);
 const p1=a.packet('UpdateObject',{id:create.id,patch:{name:'winner-a'}}),p2=b.packet('UpdateObject',{id:create.id,patch:{name:'winner-b'}});p2.expected_revision=p1.expected_revision;
 const race=await Promise.all([a.submit(p1),b.submit(p2)]);check(race.filter(r=>r.ok).length===1&&race.some(r=>r.code==='REVISION_CONFLICT'),'simultaneous same-revision edits have exactly one winner');
 await until(()=>a.state.meta.revision===b.state.meta.revision);check(a.state.objects[create.id].name===b.state.objects[create.id].name,'two observers converge on committed winner');
 const winning=race[0].ok?p1:p2,winPeer=race[0].ok?a:b,rev=a.state.meta.revision;delete winPeer.results[winning.request_id];
 check((await winPeer.submit(winning)).ok&&a.state.meta.revision===rev,'identical replay returns durable receipt without a second mutation');
 delete winPeer.results[winning.request_id];check((await winPeer.submit({...winning,payload:{id:create.id,patch:{name:'changed replay'}}})).code==='REQUEST_REUSED','request identity cannot be reused with changed payload');
 const door=Object.values(a.state.objects).find(x=>a.state.assets[x.asset_id].kind==='door'),lamp=Object.values(a.state.objects).find(x=>a.state.assets[x.asset_id].kind==='lamp');
 for(const item of [door,lamp]){const r=await a.command('SetObjectState',{id:item.id,active:!item.state.active});check(r.ok,'server persists '+a.state.assets[item.asset_id].kind+' state');await until(()=>b.state.objects[item.id].state.active===a.state.objects[item.id].state.active)}
 let mesh=Object.values(a.state.assets).find(x=>x.kind==='mesh');const good=await assetRequest(mesh.sha256,a.principal.token);
 check(good.status===200&&crypto.createHash('sha256').update(good.body).digest('hex')===mesh.sha256,'HTTPS asset fetch validates pinned certificate and exact SHA256');
 check((await assetRequest(mesh.sha256)).status===401,'unauthenticated asset fetch rejected');
 check((await assetRequest('0'.repeat(64),a.principal.token)).status===404,'unknown asset is an explicit 404');
 check(good.headers['cache-control']==='private, no-store','asset response cannot bypass future principal checks through browser cache');
 const assetFile=path.join(config.storage,'objects',mesh.sha256+'.glb');fs.renameSync(assetFile,assetFile+'.missing');
 try{check((await assetRequest(mesh.sha256,a.principal.token)).status===503,'missing registered asset produces explicit unavailable response')}finally{fs.renameSync(assetFile+'.missing',assetFile)}
 check((await assetRequest(mesh.sha256,a.principal.token)).status===200,'restoring the missing asset permits authenticated recovery');
 const fullCount=Object.keys(b.state.objects).length;
 b.send({type:'interest',centre:[10,10,0],radius:8});await until(()=>Object.keys(b.state.objects).length<fullCount);
 check(Object.keys(b.state.groups).length===0&&!b.state.objects[door.id],'AOI leave removes the whole remote group');
 b.send({type:'interest',centre:[128,140,2],radius:96});await until(()=>Object.keys(b.state.objects).length===fullCount);
 check(Object.values(b.state.objects).filter(x=>x.group_id===door.group_id).length===15,'AOI reentry restores all fifteen members');
 for(let i=0;i<15;i++){a.input([1,0]);await delay(50)}a.input([0,0]);await delay(200);
 check(a.state.avatars[a.principal.id].position[0]<128.5,'two authoritative avatar capsules collide instead of crossing');
 for(let i=0;i<20;i++){b.input([0,-1]);await delay(50)}b.input([0,0]);await delay(200);
 const before=a.state.avatars[a.principal.id].position.slice();for(let i=0;i<20;i++){a.input([1,0]);await delay(50)}a.input([0,0]);await delay(500);
 const after=a.state.avatars[a.principal.id].position.slice();check(after[0]>before[0]+2&&after[0]-before[0]<7,'server steps bounded movement input at six metres per second',{before,after,peer:b.state.avatars[b.principal.id],closed:a.closed});
 const stopped=after[0];await delay(500);check(Math.abs(a.state.avatars[a.principal.id].position[0]-stopped)<0.05,'input timeout and zero input stop movement');
 a.send({type:'input',sequence:++a.inputSeq,axis:[0,0],yaw:0,jump:false,position:[20,20,20]});await delay(150);check(a.state.avatars[a.principal.id].position[0]>100,'client position injection is ignored');
 // Solid obstacle crossing: create it directly across the avatar's eastward path.
 let obstacle=structuredClone(create);obstacle.id=crypto.randomUUID();obstacle.name='Collision test wall';obstacle.position=[after[0]+2,after[1],1.5];obstacle.size=[.5,4,3];
 check((await a.command('CreateObject',{object:obstacle})).ok,'solid collision fixture committed');
 for(let i=0;i<35;i++){a.input([1,0]);await delay(50)}a.input([0,0]);await delay(200);
 check(a.state.avatars[a.principal.id].position[0]<obstacle.position[0]-.5,'authority Jolt capsule cannot pass through a world wall');
 check(a.gaps===0&&b.gaps===0,'server streams are monotonic during movement and edits');
 check((await a.command('DeleteObject',{id:create.id})).ok,'authoritative delete commits');await until(()=>!b.state.objects[create.id]);check(!b.state.objects[create.id],'delete propagates reliably to peer');
 const receiptId=winning.request_id,oldEpoch=a.welcome.world_epoch,oldRevision=a.state.meta.revision;
 a.close();b.close();await delay(500);check(server.exitCode===null,'authority remains alive with every client closed');
 await restart();a=await (await new Peer(0).connect()).ready();
 check(a.welcome.world_epoch!==oldEpoch&&a.state.meta.revision===oldRevision,'restart uses a new epoch and restores the last committed world');
 check((await a.command('UpdateObject',{id:loose.id,patch:{name:'old epoch'}},{world_epoch:oldEpoch})).code==='EPOCH_MISMATCH','old-epoch operation rejected');
 const receiptOwner=race[0].ok?0:1;
 let query=receiptOwner===0?a:await (await new Peer(1).connect()).ready();query.send({type:'query_result',request_id:receiptId});
 check((await until(()=>query.results[receiptId])).ok,'committed result is queryable after authority restart');if(query!==a)query.close();
 a.close();await delay(200);
 // A private imported object must disappear from B's state AND asset endpoint.
 const cabin=Object.values(a.state.objects).find(x=>x.asset_id===mesh.id);config.private_objects[cabin.id]=[config.principals[0].id];await restart();
 a=await (await new Peer(0).connect()).ready();b=await (await new Peer(1).connect()).ready();
 check(a.state.objects[cabin.id]&&!b.state.objects[cabin.id]&&!b.state.assets[mesh.id],'private object and its metadata never enter unauthorized projection');
 check((await assetRequest(mesh.sha256,b.principal.token)).status===404,'knowing a private asset hash does not authorize download');
 check((await b.command('UpdateObject',{id:cabin.id,patch:{name:'leak'}})).code==='PERMISSION_DENIED','private object edit denied despite shared region editor role');
 check((await b.command('UpdateObject',{id:loose.id,patch:{asset_id:mesh.id,material:'plain'}})).code==='PERMISSION_DENIED','private asset cannot be acquired by changing a public object asset reference');
 a.close();b.close();delete config.private_objects[cabin.id];await restart();
 // V6 seeded restrictions persist in the store; config removal no longer
 // reopens the object, so lift it explicitly through the permit surface.
 a=await (await new Peer(0).connect()).ready();
 check((await a.permit('unrestrict',{object_id:cabin.id})).ok,'config-seeded restriction lifted through the permit surface');
 a.close();
 // Store process dies after SQL COMMIT: authority resolves receipt before reply.
 config.test_storage_fault='crash_after_commit';await restart();a=await (await new Peer(0).connect()).ready();
 check((await a.command('UpdateObject',{id:loose.id,patch:{name:'Recovered writer response'}})).ok,'post-commit storage process death resolves to one durable success');
 a.close();delete config.test_storage_fault;await restart();
 // Locked SQLite cannot publish the candidate; avatar stepping continues.
 a=await (await new Peer(0).connect()).ready();
 const barrier=path.join(output,'database-lock.ready');
 const lockCode='import sqlite3,time,pathlib,sys\nc=sqlite3.connect(sys.argv[1]);c.execute("BEGIN IMMEDIATE");pathlib.Path(sys.argv[2]).write_text("ready");time.sleep(8);c.rollback()';
 const lock=launch(args['--python'],['-X','utf8','-c',lockCode,path.join(config.storage,'worlds.sqlite3'),barrier],'database-lock');await until(()=>fs.existsSync(barrier));
 const tick=a.tick,oldName=a.state.objects[loose.id].name,failed=await a.command('UpdateObject',{id:loose.id,patch:{name:'Must not publish'}});
 check(!failed.ok&&a.state.objects[loose.id].name===oldName,'database write lock never reports success or exposes candidate');
 check(a.tick>tick+60,'asynchronous storage wait preserves physics stepping');await stop(lock);a.close();await delay(300);
 // Two actual Godot clients use the same LocalWorldView, asset loader and UI.
 const nativeA=new Native('editor-a',args['--visual']==='true'),nativeB=new Native('editor-b',args['--visual']==='true');
 await Promise.all([nativeA.ready(),nativeB.ready()]);await until(()=>nativeA.value.remote_avatars===1&&nativeB.value.remote_avatars===1);
 // Asset download and GLB parse finish after the first snapshot; wait for both
 // clients to reach the same steady scene before comparing node counts.
 await until(()=>nativeA.value.asset_cache_count===1&&nativeB.value.asset_cache_count===1&&nativeA.value.nodes===nativeB.value.nodes);
 check(true,'two independent native clients construct matching collision-ready scenes');
 const nativeResult=await nativeA.command('UpdateObject',{id:loose.id,patch:{name:'Two native clients'}},'edit');check(nativeResult.ok,'native UI command obtains durable server confirmation');
 await until(()=>nativeB.value.state.objects[loose.id].name==='Two native clients');check(true,'native peer displays the confirmed object update');
 nativeA.action({type:'drop_delta'});await until(()=>nativeA.value.resyncs>0);await until(()=>nativeA.value.interactive&&nativeA.value.seq>nativeB.value.seq-10);check(true,'native missing delta recovers with a full snapshot');
 nativeB.action({type:'duplicate_delta'});await until(()=>nativeB.value.duplicates>0);check(nativeB.value.interactive,'native duplicate delta is ignored');
 nativeA.action({type:'interest',centre:[10,10,0],radius:8});await until(()=>nativeA.value.nodes<3&&nativeA.value.asset_cache_count===0);check(true,'AOI exit frees native object nodes and asset cache');
 nativeA.action({type:'interest',centre:[128,140,2],radius:96});await nativeA.ready();await until(()=>nativeA.value.nodes===nativeB.value.nodes);check(nativeA.value.asset_cache_count===1,'native AOI reentry downloads and rebuilds required collisions');
 nativeA.action({type:'input',axis:[-1,0],duration_ms:1000});await delay(1800);check(nativeA.value.correction_m<0.1,'local movement prediction converges after input stops',{metres:nativeA.value.correction_m});
 // Corrupt asset + cache eviction blocks readiness and then recovers on retry.
 const blob=path.join(config.storage,'objects',mesh.sha256+'.glb'),original=fs.readFileSync(blob);fs.writeFileSync(blob,'corrupt');
 nativeA.action({type:'interest',centre:[10,10,0],radius:8});await until(()=>nativeA.value.asset_cache_count===0);nativeA.action({type:'interest',centre:[128,140,2],radius:96});
 await until(()=>Object.values(nativeA.value.asset_attempts).some(n=>n>=3)&&nativeA.value.asset_error);check(!nativeA.value.interactive,'corrupt required collision asset blocks movement after bounded retries');
 fs.writeFileSync(blob,original);nativeA.action({type:'retry_assets'});await nativeA.ready();check(nativeA.value.assets_ready,'repaired content recovers without world mutation');
 if(args['--visual']==='true'){nativeA.action({type:'screenshot'});nativeB.action({type:'screenshot'});await until(()=>fs.existsSync(path.join(nativeA.directory,'client.png'))&&fs.existsSync(path.join(nativeB.directory,'client.png')));check(true,'both rendered desktop screenshots generated');}
 nativeA.action({type:'disconnect'});await until(()=>!nativeA.value.online);nativeA.action({type:'command',operation:'UpdateObject',payload:{id:loose.id,patch:{name:'offline false success'}},label:'offline'});await delay(300);check(!nativeA.value.commands.offline&&nativeA.value.pending.length===0,'disconnected native edit is not accepted or queued as success');
 await stop(nativeA.process);await stop(nativeB.process);
 check(server.exitCode===null,'authority persists after desktop shutdown');
 for(const file of fs.readdirSync(output).filter(x=>x.endsWith('.engine.log'))){const text=fs.readFileSync(path.join(output,file),'utf8');check(!text.includes('SCRIPT ERROR'),'no authority script errors: '+file)}
}
run().catch(error=>{checks.push({name:'suite completion',passed:false,error:error.stack});console.error(error);process.exitCode=1}).finally(async()=>{for(const child of children.reverse())await stop(child).catch(()=>{});write(configPath,initialConfig);report()});
