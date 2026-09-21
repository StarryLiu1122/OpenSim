/* V6-5 end-to-end agent mission: the orchestrated hall inspection over a real
 * authority, plus reproducible failure shapes (timeout, cancel, repeat,
 * permission denial). Asserts on the mission artifacts (observations.jsonl,
 * receipts.json) and on independent world-state convergence.
 * Node built-ins only. Use a newly initialized disposable instance. */
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const {spawn} = require('child_process');
const {AgentClient, runMission} = require('./AgentMission.cjs');
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
const report=()=>write(path.join(output,'report.json'),{suite:'V6-5 agent mission end-to-end',passed:checks.length>0&&checks.every(x=>x.passed),checks});
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
const url=`ws://127.0.0.1:${config.http_port}/ws`;
class Peer{
 constructor(index){this.principal=config.principals[index];this.results={};this.state=null;this.closed=false;}
 async connect(token=this.principal.token){
  this.ws=new WebSocket(url);this.ws.onerror=()=>{};this.ws.onclose=e=>{this.closed=true;this.closeCode=e.code};
  this.ws.onmessage=e=>{const p=JSON.parse(e.data);
   if(p.type==='welcome')this.welcome=p;
   if(p.type==='snapshot')this.state=p.state;
   if(p.type==='delta'){for(const k of ['objects','groups','assets','avatars']){for(const id of p.delta.deletes[k])delete this.state[k][id];Object.assign(this.state[k],p.delta.upserts[k]);}if(p.delta.meta)this.state.meta=p.delta.meta;}
   if(p.type==='account_result')this.results[p.request_id]=p;
   if(p.type==='snapshot'||p.type==='delta')this.send({type:'ack',seq:p.seq});
  };
  await until(()=>this.ws.readyState===WebSocket.OPEN||this.closed);if(!this.closed)this.send({type:'hello',token});return this;
 }
 send(value){this.ws.send(JSON.stringify({fp_version:'0.3',...value}))}
 async ready(){await until(()=>this.state);return this}
 async account(action,params={}){const request_id=crypto.randomUUID();this.send({type:'account',request_id,action,params});return until(()=>this.results[request_id])}
 close(){if(!this.closed)this.ws.close()}
}
async function run(){
 await startServer();
 gateway=launch(config.host_executable,[configPath],'gateway');await delay(500);
 const owner=await (await new Peer(0).connect()).ready();
 const created=await owner.account('create',{name:'agent-mission',role:'agent'});
 const accountId=created.data.account.id;
 const issued=await owner.account('issue',{account_id:accountId,ttl_ms:3600000});
 check(issued.ok,'owner enrols mission agent');
 // Scenario A: the full hall-inspection mission succeeds and leaves artifacts.
 const missionDir=path.join(output,'mission');
 const result=await runMission({url,token:issued.data.token,output:missionDir,log:()=>{}});
 check(result.ok&&result.final.door_active===true&&result.final.lamp_active===true,'mission completes with door open and lamp on');
 check(!!result.queried&&result.queried.name==='室内展品','mission located the queried exhibit');
 const bundle=read(path.join(missionDir,'receipts.json'));
 check(!!bundle&&bundle.receipts.length>=9&&bundle.receipts.every(r=>(r.action==='observe'&&r.ok)||r.state==='completed'),'receipts file records every step completed');
 const lines=fs.readFileSync(path.join(missionDir,'observations.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
 check(lines.length>=5&&lines.some(l=>l.query==='室内展品'&&l.hits.length===1),'observation log records the exhibit query');
 const door=Object.values(owner.state.objects).find(x=>x.name==='展馆伸缩门');
 const lamp=Object.values(owner.state.objects).find(x=>x.name==='室内照明');
 await until(()=>owner.state.objects[door.id].state.active===true&&owner.state.objects[lamp.id].state.active===true);
 check(true,'human client converges on door and lamp states');
 await until(()=>owner.state.avatars[accountId]&&flat(owner.state.avatars[accountId].position,[128,139.5])<1.5);
 check(true,'agent avatar ends up inside the hall');
 // Scenario B: a closed door makes the same entry time out, reproducibly.
 const agent=await new AgentClient({url,token:(await owner.account('issue',{account_id:accountId,ttl_ms:3600000})).data.token}).connect();
 const closed=await agent.agent('task',{kind:'set_state',object_id:door.id,active:false});
 check((await agent.waitTask(closed.data.task.task_id)).state==='completed','door closed for the timeout scenario');
 const blocked=await agent.agent('task',{kind:'move_to',position:[128,139.5,1.5],tolerance:0.4,timeout_ms:4000});
 const stalled=await agent.waitTask(blocked.data.task.task_id,['timeout','completed'],10000);
 check(stalled.state==='timeout','entry through closed door times out');
 check(flat(agent.self().position,[128,139.5])>3,'agent stays outside the closed hall');
 // Scenario C: cancel interrupts a long walk.
 const walk=await agent.agent('task',{kind:'move_to',position:[128,170,2],tolerance:0.4,timeout_ms:60000});
 await delay(400);
 const cancelled=await agent.agent('cancel',{task_id:walk.data.task.task_id});
 check(cancelled.ok&&cancelled.data.task.state==='cancelled','long walk cancelled mid-mission');
 // Scenario D: repeating the same set_state is idempotent and both succeed.
 const first=await agent.agent('task',{kind:'set_state',object_id:door.id,active:true});
 check((await agent.waitTask(first.data.task.task_id)).state==='completed','reopen door after scenarios');
 const again=await agent.agent('task',{kind:'set_state',object_id:door.id,active:true});
 check((await agent.waitTask(again.data.task.task_id)).state==='completed','repeated set_state also completes');
 await until(()=>owner.state.objects[door.id].state.active===true);
 check(true,'door state converges after repeated operation');
 const history=await agent.agent('status');
 check(history.ok&&history.data.tasks.length>=4,'task history covers all scenario tasks');
 agent.close();
 // Scenario E: an observer driving the same mission step is refused.
 const observer=await new AgentClient({url,token:config.principals[2].token}).connect();
 check((await observer.agent('task',{kind:'set_state',object_id:door.id,active:false})).code==='PERMISSION_DENIED','observer mission step refused');
 check((await observer.agent('observe')).ok,'observer still observes');
 observer.close();owner.close();
 const log=fs.readFileSync(path.join(output,'authority-1.engine.log'),'utf8');
 check(!/SCRIPT ERROR|Parse Error/i.test(log),'no authority script errors');
 await stop(gateway);await stop(server);
}
run().catch(async error=>{console.error(error);for(const child of children)await stop(child);process.exitCode=1});
