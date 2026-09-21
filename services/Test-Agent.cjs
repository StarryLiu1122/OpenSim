/* V6 controlled agent surface over the real authority: agent role lockdown,
 * observation, the asynchronous task whitelist (move_to / create_box /
 * update_object / set_state), timeout, cancel, status and restart durability.
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
const report=()=>write(path.join(output,'report.json'),{suite:'V6 agent surface',passed:checks.length>0&&checks.every(x=>x.passed),checks});
function check(value,name){checks.push({name,passed:!!value});console.log(`${value?'PASS':'FAIL'} ${name}`);report();if(!value)throw Error(name)}
async function until(fn,timeout=15000){const end=Date.now()+timeout;for(;;){const value=fn();if(value)return value;if(Date.now()>end)throw Error('Timed out: '+fn.toString().slice(0,180));await delay(40)}}
function launch(exe,argv,name,env={}){const fd=fs.openSync(path.join(output,name+'.log'),'w');const child=spawn(exe,argv,{windowsHide:true,stdio:['ignore',fd,fd],env:{...process.env,...env}});fs.closeSync(fd);children.push(child);return child}
async function stop(child){if(child&&child.exitCode===null){child.kill();await until(()=>child.exitCode!==null||child.signalCode!==null,10000)}}
async function startServer(){
  write(configPath,config);const ready=path.join(config.storage,'server-ready.json');if(fs.existsSync(ready))fs.unlinkSync(ready);
  generation++;server=launch(config.godot,['--headless','--path',config.project,'--log-file',path.join(output,`authority-${generation}.engine.log`),'res://network/server.tscn','--','--network-config='+configPath],`authority-${generation}`);
  return until(()=>read(ready),45000);
}
const flat=(a,b)=>Math.hypot(a[0]-b[0],a[1]-b[1]);
const BUILTIN='22222222-2222-4222-8222-';
class Peer{
 constructor(index){this.principal=config.principals[index];this.seq=0;this.messages=[];this.results={};this.events=[];this.state=null;this.closed=false;}
 async connect(token=this.principal.token,url=`ws://127.0.0.1:${config.http_port}/ws`){
  this.ws=new WebSocket(url);this.ws.onerror=()=>{};this.ws.onclose=e=>{this.closed=true;this.closeCode=e.code;this.closeReason=e.reason};
  this.ws.onmessage=e=>{const p=JSON.parse(e.data);this.messages.push(p);if(this.messages.length>300)this.messages.shift();
   if(p.type==='welcome')this.welcome=p;
   if(p.type==='snapshot'){this.state=p.state;this.stream=p.seq;}
   if(p.type==='delta'){this.stream=p.seq;for(const k of ['objects','groups','assets','avatars']){for(const id of p.delta.deletes[k])delete this.state[k][id];Object.assign(this.state[k],p.delta.upserts[k]);}if(p.delta.meta)this.state.meta=p.delta.meta;}
   if(['result','permit_result','account_result','inventory_result','agent_result'].includes(p.type))this.results[p.request_id]=p;
   if(p.type==='agent_event')this.events.push(p.task);
   if(p.type==='snapshot'||p.type==='delta')this.send({type:'ack',seq:p.seq});
  };
  await until(()=>this.ws.readyState===WebSocket.OPEN||this.closed);if(!this.closed)this.send({type:'hello',token});return this;
 }
 send(value){this.ws.send(JSON.stringify({fp_version:'0.3',...value}))}
 async ready(){await until(()=>this.state);return this}
 async account(action,params={}){const request_id=crypto.randomUUID();this.send({type:'account',request_id,action,params});return until(()=>this.results[request_id])}
 async agent(action,params={}){const request_id=crypto.randomUUID();this.send({type:'agent',request_id,action,params});return until(()=>this.results[request_id])}
 async permit(action,params={}){const request_id=crypto.randomUUID();this.send({type:'permit',request_id,action,params});return until(()=>this.results[request_id])}
 async inventory(action,params={}){const request_id=crypto.randomUUID();this.send({type:'inventory',request_id,action,params});return until(()=>this.results[request_id])}
 packet(operation,payload,extra={}){return {fp_version:'0.3',type:'command',world_id:this.welcome.world_id,region_id:this.welcome.region_id,world_epoch:this.welcome.world_epoch,request_id:crypto.randomUUID(),trace_id:crypto.randomUUID(),origin:'test',source_seq:++this.seq,expected_revision:this.state.meta.revision,expires_at_ms:Date.now()+30000,operation,payload,...extra}}
 async command(op,payload,extra){const p=this.packet(op,payload,extra);this.send(p);const result=await until(()=>this.results[p.request_id]);if(result.ok)await until(()=>this.state.meta.revision>=result.revision);return result}
 waitTask(taskId,states,timeout=15000){return until(()=>this.events.find(t=>t.task_id===taskId&&states.includes(t.state)),timeout)}
 close(){if(!this.closed)this.ws.close()}
}
async function run(){
 await startServer();
 gateway=launch(config.host_executable,[configPath],'gateway');await delay(500);
 const owner=await (await new Peer(0).connect()).ready();
 check(owner.welcome.role==='owner','owner bootstrap');
 // The owner enrols an agent account; the role survives in the directory.
 const created=await owner.account('create',{name:'agent-v6',role:'agent'});
 check(created.ok&&created.data.account.role==='agent','owner creates agent account');
 const accountId=created.data.account.id;
 const issued=await owner.account('issue',{account_id:accountId,ttl_ms:3600000});
 check(issued.ok,'owner issues agent session');
 const agent=await (await new Peer(0).connect(issued.data.token)).ready();
 check(agent.welcome.role==='agent'&&agent.welcome.principal_id===accountId,'agent session welcomed with agent role');
 const observer=await (await new Peer(2).connect()).ready();
 await until(()=>!!owner.state.avatars[accountId]);
 const start=owner.state.avatars[accountId].position.slice();
 // Role lockdown: raw commands, avatar input, inventory, permits, management.
 const anyBox=Object.values(agent.state.objects).find(x=>x.asset_id.startsWith(BUILTIN));
 check((await agent.command('UpdateObject',{id:anyBox.id,patch:{name:'forbidden'}})).code==='PERMISSION_DENIED','agent raw command refused');
 agent.send({type:'input',sequence:1,axis:[1,0],yaw:0,jump:false});
 await delay(500);
 check(flat(owner.state.avatars[accountId].position,start)<0.05,'agent raw avatar input ignored');
 check((await agent.inventory('list')).code==='PERMISSION_DENIED','agent inventory refused');
 check((await agent.permit('restrict',{object_id:anyBox.id})).code==='PERMISSION_DENIED','agent permit management refused');
 check((await agent.account('list')).code==='PERMISSION_DENIED','agent account management refused');
 // Observation mirrors the live projection.
 const observed=await agent.agent('observe');
 check(observed.ok&&observed.data.state.meta.revision===agent.state.meta.revision&&Object.keys(observed.data.state.objects).length>0,'agent observes the world');
 check((await agent.agent('frobnicate')).code==='UNSUPPORTED_AGENT_ACTION','unknown agent action refused');
 agent.send({type:'agent',request_id:'not-a-uuid',action:'observe',params:{}});const malformed=await until(()=>Object.values(agent.results).find(r=>r.ok===false&&r.code==='INVALID_AGENT_REQUEST'));
 check(!!malformed,'malformed agent packet refused');
 // move_to completes and every client sees the avatar arrive.
 const target=[start[0]+2.5,start[1],start[2]];
 const move=await agent.agent('task',{kind:'move_to',position:target,tolerance:0.3,timeout_ms:10000});
 check(move.ok&&move.data.task.state==='running','move_to accepted as running');
 const moved=await agent.waitTask(move.data.task.task_id,['completed','failed','timeout'],12000);
 check(moved.state==='completed'&&flat(moved.detail.position,target)<0.6,'move_to completes at destination');
 await until(()=>owner.state.avatars[accountId]&&flat(owner.state.avatars[accountId].position,target)<0.6);
 check(true,'owner sees agent avatar at destination');
 // create_box mutates the world through the standard queue.
 const boxPos=[start[0],start[1]+2.5,0.5];
 const made=await agent.agent('task',{kind:'create_box',position:boxPos,name:'智能体箱体',size:[1,1,1],color:'#ff8800'});
 check(made.ok&&made.data.task.state==='accepted','create_box queued');
 const built=await agent.waitTask(made.data.task.task_id,['completed','failed','timeout']);
 check(built.state==='completed'&&built.detail.revision>0,'create_box completes: '+built.state+'/'+built.code);
 await until(()=>owner.state.meta.revision>=built.detail.revision);
 const box=Object.values(owner.state.objects).find(x=>x.name==='智能体箱体');
 check(!!box&&box.color==='#ff8800','created box visible to every client');
 // update_object patches builtin primitives only, keys whitelisted.
 const renamed=await agent.agent('task',{kind:'update_object',object_id:box.id,patch:{name:'重命名箱体',color:'#ff0000'}});
 const patched=await agent.waitTask(renamed.data.task.task_id,['completed','failed']);
 check(patched.state==='completed','update_object completes on builtin primitive');
 await until(()=>owner.state.objects[box.id]&&owner.state.objects[box.id].name==='重命名箱体');
 check(owner.state.objects[box.id].color==='#ff0000','renamed box converges for owner');
 const cabin=Object.values(agent.state.objects).find(x=>!x.asset_id.startsWith(BUILTIN));
 check(!!cabin,'fixture mesh object present');
 check((await agent.agent('task',{kind:'update_object',object_id:cabin.id,patch:{name:'x'}})).code==='AGENT_TARGET_UNSUPPORTED','mesh object refused for cosmetic patch');
 check((await agent.agent('task',{kind:'update_object',object_id:box.id,patch:{position:[0,0,0]}})).code==='AGENT_PATCH_FORBIDDEN','patch keys outside whitelist refused');
 // set_state drives door and lamp behavior state.
 const door=Object.values(agent.state.objects).find(x=>x.name==='展馆伸缩门');
 const lamp=Object.values(agent.state.objects).find(x=>x.name==='步道路灯');
 const opened=await agent.agent('task',{kind:'set_state',object_id:door.id,active:true});
 check((await agent.waitTask(opened.data.task.task_id,['completed','failed'])).state==='completed','door opens via set_state');
 await until(()=>owner.state.objects[door.id]&&owner.state.objects[door.id].state.active===true);
 check(true,'door state converges for owner');
 const darkened=await agent.agent('task',{kind:'set_state',object_id:lamp.id,active:false});
 check((await agent.waitTask(darkened.data.task.task_id,['completed','failed'])).state==='completed','lamp switches off via set_state');
 await until(()=>owner.state.objects[lamp.id]&&owner.state.objects[lamp.id].state.active===false);
 check(true,'lamp state converges for owner');
 check((await agent.agent('task',{kind:'set_state',object_id:box.id,active:true})).code==='AGENT_TARGET_UNSUPPORTED','stateless object refused for set_state');
 check((await agent.agent('task',{kind:'set_state',object_id:crypto.randomUUID(),active:true})).code==='AGENT_TARGET_UNKNOWN','unknown object refused for set_state');
 // Validation failures are explicit.
 check((await agent.agent('task',{kind:'teleport',position:[0,0,0]})).code==='AGENT_TASK_UNSUPPORTED','kind outside whitelist refused');
 check((await agent.agent('task',{kind:'move_to',position:'north'})).code==='INVALID_AGENT_TASK','malformed move_to refused');
 // A short deadline times the task out and stops the avatar.
 const far=[start[0]+30,start[1]+30,2];
 const rushed=await agent.agent('task',{kind:'move_to',position:far,tolerance:0.3,timeout_ms:1200});
 const expired=await agent.waitTask(rushed.data.task.task_id,['timeout','completed'],10000);
 check(expired.state==='timeout','short move_to times out');
 await delay(400);const parked=owner.state.avatars[accountId].position.slice();await delay(400);
 check(flat(owner.state.avatars[accountId].position,parked)<0.2,'avatar stops after timeout');
 // Cancel halts a running task; cancelling a finished task is idempotent.
 const cruise=await agent.agent('task',{kind:'move_to',position:far,tolerance:0.3,timeout_ms:60000});
 await delay(300);
 const cancelled=await agent.agent('cancel',{task_id:cruise.data.task.task_id});
 check(cancelled.ok&&cancelled.data.task.state==='cancelled','running task cancelled');
 await delay(500);const halted=owner.state.avatars[accountId].position.slice();await delay(400);
 check(flat(owner.state.avatars[accountId].position,halted)<0.2,'avatar stops after cancel');
 check((await agent.agent('cancel',{task_id:move.data.task.task_id})).data.task.state==='completed','cancelling a finished task reports its state');
 check((await agent.agent('cancel',{task_id:crypto.randomUUID()})).code==='TASK_UNKNOWN','cancel of unknown task refused');
 // Status lists the agent's own task history.
 const listed=await agent.agent('status');
 const states=Object.fromEntries(listed.data.tasks.map(t=>[t.task_id,t.state]));
 check(listed.ok&&states[move.data.task.task_id]==='completed'&&states[rushed.data.task.task_id]==='timeout'&&states[cruise.data.task.task_id]==='cancelled','status reports task history');
 const single=await agent.agent('status',{task_id:cruise.data.task.task_id});
 check(single.ok&&single.data.tasks.length===1&&single.data.tasks[0].kind==='move_to','status filters by task_id');
 check((await agent.agent('status',{task_id:crypto.randomUUID()})).code==='TASK_UNKNOWN','status of unknown task refused');
 // Observers may observe but never act.
 check((await observer.agent('observe')).ok,'observer observes');
 check((await observer.agent('status')).ok,'observer reads empty task list');
 check((await observer.agent('task',{kind:'create_box',position:boxPos})).code==='PERMISSION_DENIED','observer cannot submit tasks');
 // Disconnect abandons running tasks and frees the avatar.
 const abandoned=await agent.agent('task',{kind:'move_to',position:far,tolerance:0.3,timeout_ms:60000});
 check(abandoned.ok,'long move_to running before disconnect');
 agent.close();await until(()=>!owner.state.avatars[accountId]);
 check(true,'disconnect frees agent avatar and abandons tasks');
 observer.close();
 // Restart: the agent role survives in the rebuilt accounts table.
 owner.close();await stop(server);await startServer();
 const owner2=await (await new Peer(0).connect()).ready();
 const reissued=await owner2.account('issue',{account_id:accountId,ttl_ms:3600000});
 check(reissued.ok,'agent account survives restart');
 const agent2=await (await new Peer(0).connect(reissued.data.token)).ready();
 check(agent2.welcome.role==='agent','agent role persists across restart');
 check((await agent2.agent('observe')).ok,'agent observes after restart');
 agent2.close();owner2.close();
 for(const name of ['authority-1.engine.log','authority-2.engine.log']){
  const log=fs.readFileSync(path.join(output,name),'utf8');
  check(!/SCRIPT ERROR|Parse Error/i.test(log),'no authority script errors: '+name);
 }
 await stop(gateway);await stop(server);
}
run().catch(async error=>{console.error(error);for(const child of children)await stop(child);process.exitCode=1});
