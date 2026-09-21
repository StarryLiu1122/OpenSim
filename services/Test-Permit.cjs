/* V6 permit lifecycle over the real authority: object restrictions, grants,
 * two-client convergence, config seeding and restart persistence.
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
const report=()=>write(path.join(output,'report.json'),{suite:'V6 permit lifecycle',passed:checks.length>0&&checks.every(x=>x.passed),checks});
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
   if(p.type==='result'||p.type==='permit_result')this.results[p.request_id]=p;
   if(p.type==='snapshot'||p.type==='delta')this.send({type:'ack',seq:p.seq});
  };
  await until(()=>this.ws.readyState===WebSocket.OPEN||this.closed);if(!this.closed)this.send({type:'hello',token});return this;
 }
 send(value){this.ws.send(JSON.stringify({fp_version:'0.3',...value}))}
 async ready(){await until(()=>this.state);return this}
 async permit(action,params={}){const request_id=crypto.randomUUID();this.send({type:'permit',request_id,action,params});return until(()=>this.results[request_id])}
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
 const guest=await (await new Peer(3).connect()).ready();
 const loose=Object.values(a.state.objects).find(x=>!x.group_id&&x.asset_id==='22222222-2222-4222-8222-222222222222');
 check(!!loose&&!!b.state.objects[loose.id]&&!!observer.state.objects[loose.id],'fixture object visible to every role by default');
 // Restrict: only the restricting owner keeps automatic access.
 const applied=await a.permit('restrict',{object_id:loose.id});
 check(applied.ok&&applied.data.restricted===true,'owner restricts object');
 await until(()=>!b.state.objects[loose.id]&&!observer.state.objects[loose.id]);
 check(!!a.state.objects[loose.id],'restriction converges: others lose it, owner keeps it');
 // Denied mutation leaves the world unchanged.
 const before=a.state.meta.revision;
 check((await b.command('UpdateObject',{id:loose.id,patch:{name:'forbidden'}})).code==='PERMISSION_DENIED','ungranted editor mutation refused');
 await delay(300);check(a.state.meta.revision===before,'refused mutation leaves world unchanged');
 // Grant restores visibility and editing in real time.
 check((await a.permit('grant',{object_id:loose.id,account_id:b.principal.id})).ok,'owner grants editor');
 await until(()=>!!b.state.objects[loose.id]);check(true,'grant converges: editor sees object again');
 check((await b.command('UpdateObject',{id:loose.id,patch:{name:'shared edit'}})).ok,'granted editor mutates the object');
 // Revoke removes access in real time.
 check((await a.permit('revoke',{object_id:loose.id,account_id:b.principal.id})).ok,'owner revokes editor');
 await until(()=>!b.state.objects[loose.id]);check(true,'revoke converges: editor loses object again');
 check((await b.command('UpdateObject',{id:loose.id,patch:{name:'forbidden'}})).code==='PERMISSION_DENIED','revoked editor mutation refused again');
 // Granted observer sees but still cannot mutate.
 check((await a.permit('grant',{object_id:loose.id,account_id:observer.principal.id})).ok,'owner grants observer');
 await until(()=>!!observer.state.objects[loose.id]);check(true,'granted observer sees object');
 check((await observer.command('UpdateObject',{id:loose.id,patch:{name:'forbidden'}})).code==='PERMISSION_DENIED','granted observer stays read-only');
 // Default-deny management: non-owner actors and observers cannot permit.
 check((await guest.permit('restrict',{object_id:loose.id})).code==='PERMISSION_DENIED','foreign actor cannot restrict');
 check((await observer.permit('unrestrict',{object_id:loose.id})).code==='PERMISSION_DENIED','observer cannot manage permits');
 check((await a.permit('restrict',{object_id:crypto.randomUUID()})).code==='OBJECT_UNKNOWN','unknown object refused');
 check((await a.permit('grant',{object_id:loose.id,account_id:crypto.randomUUID()})).code==='ACCOUNT_NOT_FOUND','grant to unknown account refused');
 check((await a.permit('frobnicate',{object_id:loose.id})).code==='UNSUPPORTED_PERMIT_ACTION','unknown permit action refused');
 check((await a.permit('restrict',{})).code==='INVALID_PERMIT_REQUEST','malformed permit refused');
 const listed=await a.permit('list');
 check(listed.ok&&listed.data.restrictions.length===1&&listed.data.restrictions[0].exists===true,'permit list shows live restriction');
 // Lifting the restriction retires grants and reopens the object.
 check((await a.permit('unrestrict',{object_id:loose.id})).ok,'owner lifts restriction');
 await until(()=>!!b.state.objects[loose.id]&&!!observer.state.objects[loose.id]);check(true,'unrestricted object visible to all again');
 check((await a.permit('list')).data.restrictions.length===0,'lifting retires grants');
 // Group semantics: one restricted member hides the whole fifteen-part group.
 const door=Object.values(a.state.objects).find(x=>x.group_id);
 check(!!door&&Object.values(observer.state.objects).filter(x=>x.group_id===door.group_id).length===15,'door group fully visible before restriction');
 check((await a.permit('restrict',{object_id:door.id})).ok,'owner restricts one group member');
 await until(()=>Object.values(observer.state.objects).filter(x=>x.group_id===door.group_id).length===0&&!observer.state.groups[door.group_id]);
 check(Object.values(a.state.objects).filter(x=>x.group_id===door.group_id).length===15,'restricted member hides whole group for others only');
 check((await a.permit('unrestrict',{object_id:door.id})).ok,'owner reopens group member');
 await until(()=>Object.values(observer.state.objects).filter(x=>x.group_id===door.group_id).length===15);check(true,'group fully restored after unrestrict');
 // Config seeding: restart with private_objects and the registry adopts them.
 a.close();b.close();observer.close();guest.close();await stop(server);
 config.private_objects={[loose.id]:[config.principals[0].id,config.principals[1].id]};
 await startServer();
 const a2=await (await new Peer(0).connect()).ready();
 const b2=await (await new Peer(1).connect()).ready();
 const observer2=await (await new Peer(2).connect()).ready();
 check(!!a2.state.objects[loose.id]&&!!b2.state.objects[loose.id]&&!observer2.state.objects[loose.id],'config private_objects seed restriction and grants');
 const seeded=await a2.permit('list');
 check(seeded.data.restrictions.some(r=>r.object_id===loose.id&&r.accounts.length===2),'seeded permits listed');
 // Runtime changes survive another restart without config.
 check((await a2.permit('revoke',{object_id:loose.id,account_id:b2.principal.id})).ok,'owner revokes seeded grant');
 a2.close();b2.close();observer2.close();await stop(server);
 delete config.private_objects[loose.id];
 await startServer();
 const a3=await (await new Peer(0).connect()).ready();
 const b3=await (await new Peer(1).connect()).ready();
 const observer3=await (await new Peer(2).connect()).ready();
 check(!!a3.state.objects[loose.id]&&!b3.state.objects[loose.id]&&!observer3.state.objects[loose.id],'runtime permits persist across restart');
 check((await a3.permit('unrestrict',{object_id:loose.id})).ok,'cleanup: restriction lifted');
 a3.close();b3.close();observer3.close();
 for(const name of ['authority-1.engine.log','authority-2.engine.log','authority-3.engine.log']){
  const log=fs.readFileSync(path.join(output,name),'utf8');
  check(!/SCRIPT ERROR|Parse Error/i.test(log),'no authority script errors: '+name);
 }
 await stop(gateway);await stop(server);
}
run().catch(async error=>{console.error(error);for(const child of children)await stop(child);process.exitCode=1});
