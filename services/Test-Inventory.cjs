/* V6 inventory lifecycle over the real authority: folders, content-referencing
 * items, placement sharing one content, give/remove and restart persistence.
 * Node built-ins only. Use a newly initialized disposable instance. */
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const {spawn} = require('child_process');
const args = Object.fromEntries(process.argv.slice(2).map(s => { const i=s.indexOf('='); return [s.slice(0,i),s.slice(i+1)]; }));
const configPath=path.resolve(args['--config']), output=path.resolve(args['--output']);
if (fs.existsSync(output)) throw Error('Use a new output directory');
fs.mkdirSync(output,{recursive:true});
const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));
const children=[], checks=[];
let server, gateway, generation=0;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const read=p=>{try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}};
const write=(p,v)=>{fs.writeFileSync(p+'.tmp',JSON.stringify(v));fs.renameSync(p+'.tmp',p)};
const report=()=>write(path.join(output,'report.json'),{suite:'V6 inventory lifecycle',passed:checks.length>0&&checks.every(x=>x.passed),checks});
function check(value,name){checks.push({name,passed:!!value});console.log(`${value?'PASS':'FAIL'} ${name}`);report();if(!value)throw Error(name)}
async function until(fn,timeout=15000){const end=Date.now()+timeout;for(;;){const value=fn();if(value)return value;if(Date.now()>end)throw Error('Timed out: '+fn.toString().slice(0,180));await delay(40)}}
function launch(exe,argv,name,env={}){const fd=fs.openSync(path.join(output,name+'.log'),'w');const child=spawn(exe,argv,{windowsHide:true,stdio:['ignore',fd,fd],env:{...process.env,...env}});fs.closeSync(fd);children.push(child);return child}
async function stop(child){if(child&&child.exitCode===null){child.kill();await until(()=>child.exitCode!==null||child.signalCode!==null,10000)}}
async function startServer(){
  write(configPath,config);const ready=path.join(config.storage,'server-ready.json');if(fs.existsSync(ready))fs.unlinkSync(ready);
  generation++;server=launch(config.godot,['--headless','--path',config.project,'--log-file',path.join(output,`authority-${generation}.engine.log`),'res://network/server.tscn','--','--network-config='+configPath],`authority-${generation}`);
  return until(()=>read(ready),45000);
}
class Peer{
 constructor(index){this.principal=config.principals[index];this.seq=0;this.messages=[];this.results={};this.state=null;this.closed=false;}
 async connect(token=this.principal.token,url=`ws://127.0.0.1:${config.http_port}/ws`){
  this.ws=new WebSocket(url);this.ws.onerror=()=>{};this.ws.onclose=e=>{this.closed=true;this.closeCode=e.code};
  this.ws.onmessage=e=>{const p=JSON.parse(e.data);this.messages.push(p);if(this.messages.length>300)this.messages.shift();
   if(p.type==='welcome')this.welcome=p;
   if(p.type==='snapshot'){this.state=p.state;this.stream=p.seq;}
   if(p.type==='delta'){this.stream=p.seq;for(const k of ['objects','groups','assets','avatars']){for(const id of p.delta.deletes[k])delete this.state[k][id];Object.assign(this.state[k],p.delta.upserts[k]);}if(p.delta.meta)this.state.meta=p.delta.meta;}
   if(p.type==='result'||p.type==='inventory_result')this.results[p.request_id]=p;
   if(p.type==='snapshot'||p.type==='delta')this.send({type:'ack',seq:p.seq});
  };
  await until(()=>this.ws.readyState===WebSocket.OPEN||this.closed);if(!this.closed)this.send({type:'hello',token});return this;
 }
 send(value){this.ws.send(JSON.stringify({fp_version:'0.3',...value}))}
 async ready(){await until(()=>this.state);return this}
 async inventory(action,params={}){const request_id=crypto.randomUUID();this.send({type:'inventory',request_id,action,params});return until(()=>this.results[request_id])}
 packet(operation,payload,extra={}){return {fp_version:'0.3',type:'command',world_id:this.welcome.world_id,region_id:this.welcome.region_id,world_epoch:this.welcome.world_epoch,request_id:crypto.randomUUID(),trace_id:crypto.randomUUID(),origin:'test',source_seq:++this.seq,expected_revision:this.state.meta.revision,expires_at_ms:Date.now()+30000,operation,payload,...extra}}
 async command(op,payload,extra){const p=this.packet(op,payload,extra);this.send(p);const result=await until(()=>this.results[p.request_id]);if(result.ok)await until(()=>this.state.meta.revision>=result.revision);return result}
 close(){if(!this.closed)this.ws.close()}
}
async function run(){
 await startServer();
 gateway=launch(config.host_executable,[configPath],'gateway');await delay(500);
 const a=await (await new Peer(0).connect()).ready();
 const b=await (await new Peer(1).connect()).ready();
 const observer=await (await new Peer(2).connect()).ready();
 // Upload a mesh through the existing command path, then shelve it.
 const glb=fs.readFileSync(path.join(__dirname,'..','prototype','fixtures','meshes','bench.glb')).toString('base64');
 const uploaded=await a.command('UploadAsset',{bytes:glb,name:'Inventory bench',license:'CC0-1.0',attribution:'Region Lab fixture'});
 check(uploaded.ok&&uploaded.payload.id,'mesh uploaded through command queue');
 const assetId=uploaded.payload.id;
 const folder=await a.inventory('folder_create',{name:'furniture'});
 check(folder.ok,'inventory folder created');
 check((await a.inventory('folder_create',{name:'bad',parent_id:crypto.randomUUID()})).code==='FOLDER_NOT_FOUND','folder with unknown parent refused');
 const added=await a.inventory('add',{asset_id:assetId,folder_id:folder.data.folder.id});
 check(added.ok&&added.data.item.asset_sha256.length===64,'uploaded asset shelved into folder');
 const itemId=added.data.item.id;
 const sha=added.data.item.asset_sha256;
 const originalBounds=added.data.item.bounds;
 check((await a.command('RemoveAsset',{id:assetId})).ok,'shelved asset can leave the world catalog');
 const shelved=(await a.inventory('list')).data.items[0];
 check(Array.isArray(shelved.bounds)&&shelved.bounds.every((value,index)=>Math.abs(value-originalBounds[index])<1e-5),'inventory-only content exposes verified bounds after leaving world catalog');
 check(!shelved.asset_error,'healthy inventory-only content remains placeable');
 check((await a.inventory('add',{asset_id:crypto.randomUUID()})).code==='ASSET_UNKNOWN','shelving unknown asset refused');
 check((await b.inventory('remove',{item_id:itemId})).code==='ITEM_NOT_FOUND','other account cannot see the item');
 // Place twice: two instances share one world asset and one content file.
 check((await a.command('PlaceInventoryItem',{item_id:itemId,position:[140,140,6.5],rotation:[0,0,0,0]})).code==='INVALID_PLACEMENT','non-unit inventory rotation is rejected before import');
 const quarterTurn=[0,0,Math.SQRT1_2,Math.SQRT1_2];
 const placed1=await a.command('PlaceInventoryItem',{item_id:itemId,position:[140,140,6.5],rotation:quarterTurn});
 check(placed1.ok,'first placement committed');
 const placed2=await a.command('PlaceInventoryItem',{item_id:itemId,position:[150,140,0]});
 check(placed2.ok,'second placement committed');
 const meshAssets=Object.values(a.state.assets).filter(x=>x.sha256===sha);
 check(meshAssets.length===1,'both instances share one world asset record');
 const instances=Object.values(a.state.objects).filter(x=>x.asset_id===meshAssets[0].id);
 check(instances.length===2,'two scene instances reference the shared asset');
 check(Math.abs(instances.find(x=>x.position[0]===140).position[2]-6.5)<1e-5,'fresh inventory import preserves requested center height');
 check(instances.find(x=>x.position[0]===140).rotation.every((value,index)=>Math.abs(value-quarterTurn[index])<1e-5),'inventory placement persists requested rotation');
 check((await a.inventory('list')).data.items[0].bounds[2]===meshAssets[0].bounds[2],'inventory lists true bounds after content enters world');
 const edgePosition=[originalBounds[0]/2+0.05,originalBounds[1]/2+0.05,originalBounds[2]/2+0.05];
 const edgePlacement=await a.command('PlaceInventoryItem',{item_id:itemId,position:edgePosition});
 check(edgePlacement.ok&&edgePlacement.payload.id,'verified inventory bounds permit placement close to region edge');
 check((await a.command('DeleteObject',{id:edgePlacement.payload.id})).ok,'near-edge regression instance cleaned up');
 const files=fs.readdirSync(path.join(config.storage,'objects')).filter(f=>f.startsWith(sha));
 check(files.length===1,'one content file serves every instance');
 // Deleting an instance never touches the inventory entry.
 check((await a.command('DeleteObject',{id:instances[0].id})).ok,'one instance deleted');
 const listing=await a.inventory('list');
 check(listing.data.items.some(x=>x.id===itemId),'inventory entry survives instance deletion');
 check((await a.command('PlaceInventoryItem',{item_id:itemId,position:[145,150,0]})).ok,'placement still works after deletion');
 // Observer is read-only for placement but keeps a personal inventory.
 check((await observer.command('PlaceInventoryItem',{item_id:itemId,position:[140,150,0]})).code==='PERMISSION_DENIED','observer cannot place');
 check((await observer.inventory('list')).ok,'observer inventory is personal and readable');
 // Give: transfer to another account; the giver loses it.
 check((await a.inventory('give',{item_id:itemId,to_account_id:crypto.randomUUID()})).code==='ACCOUNT_NOT_FOUND','give to unknown account refused');
 check((await a.inventory('give',{item_id:itemId,to_account_id:b.principal.id})).ok,'item given to editor-b');
 check(!(await a.inventory('list')).data.items.length,'giver inventory empty after give');
 check((await b.inventory('list')).data.items.some(x=>x.id===itemId&&x.folder_id===null),'recipient holds the item at root');
 check((await b.command('PlaceInventoryItem',{item_id:itemId,position:[135,145,0]})).ok,'recipient places the received item');
 // Move and remove.
 const bFolder=await b.inventory('folder_create',{name:'shared'});
 check((await b.inventory('move',{item_id:itemId,folder_id:bFolder.data.folder.id})).ok,'recipient files the item');
 check((await b.inventory('remove',{item_id:itemId})).ok,'recipient removes the item');
 check((await b.command('PlaceInventoryItem',{item_id:itemId,position:[135,140,0]})).code==='ITEM_NOT_FOUND','removed item cannot be placed');
 // Malformed requests.
 check((await a.inventory('frobnicate')).code==='UNSUPPORTED_INVENTORY_ACTION','unknown inventory action refused');
 check((await a.inventory('add',{})).code==='INVALID_INVENTORY_REQUEST','malformed add refused');
 // Restart: folders and items persist.
 check((await a.inventory('add',{asset_id:assetId,name:'kept'})).ok,'item shelved for restart');
 a.close();b.close();observer.close();await stop(server);await startServer();
 const a2=await (await new Peer(0).connect()).ready();
 const restored=await a2.inventory('list');
 check(restored.data.folders.length===1&&restored.data.items.length===1,'inventory persists across authority restart');
 const keptId=restored.data.items[0].id;
 check((await a2.command('PlaceInventoryItem',{item_id:keptId,position:[130,140,0]})).ok,'restored item places after restart');
 a2.close();
 for(const name of ['authority-1.engine.log','authority-2.engine.log']){
  const log=fs.readFileSync(path.join(output,name),'utf8');
  check(!/SCRIPT ERROR|Parse Error/i.test(log),'no authority script errors: '+name);
 }
 await stop(gateway);await stop(server);
}
run().catch(async error=>{console.error(error);for(const child of children)await stop(child);process.exitCode=1});
