/* V6 identity lifecycle over the real authority: owner bootstrap, account
 * management, hashed sessions, in-frame revocation and durable restart.
 * Node built-ins only. Use a newly initialized disposable instance. */
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const {spawn} = require('child_process');
const args = Object.fromEntries(process.argv.slice(2).map(s => { const i=s.indexOf('='); return [s.slice(0,i),s.slice(i+1)]; }));
const configPath=path.resolve(args['--config']), output=path.resolve(args['--output']);
if (fs.existsSync(output)) throw Error('Use a new output directory');
fs.mkdirSync(output,{recursive:true});
const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));const children=[], checks=[];
let server, gateway, generation=0;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const read=p=>{try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}};
const write=(p,v)=>{fs.writeFileSync(p+'.tmp',JSON.stringify(v));fs.renameSync(p+'.tmp',p)};
const report=()=>write(path.join(output,'report.json'),{suite:'V6 identity lifecycle',passed:checks.length>0&&checks.every(x=>x.passed),checks});
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
 constructor(index){this.principal=config.principals[index];this.messages=[];this.results={};this.state=null;this.closed=false;}
 async connect(token=this.principal.token,url=`ws://127.0.0.1:${config.http_port}/ws`){
  this.ws=new WebSocket(url);this.ws.onerror=()=>{};this.ws.onclose=e=>{this.closed=true;this.closeCode=e.code;this.closeReason=e.reason};
  this.ws.onmessage=e=>{const p=JSON.parse(e.data);this.messages.push(p);if(this.messages.length>300)this.messages.shift();
   if(p.type==='welcome')this.welcome=p;
   if(p.type==='snapshot')this.state=p.state;
   if(p.type==='account_result')this.results[p.request_id]=p;
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
 // Configured principal zero bootstraps as the durable owner.
 const owner=await (await new Peer(0).connect()).ready();
 check(owner.welcome.role==='owner','first configured principal bootstraps as owner');
 const listed=await owner.account('list');
 check(listed.ok&&listed.data.accounts.length===config.principals.length,'bootstrap registers every configured principal');
 check(listed.data.sessions.every(s=>/^[a-f0-9]{64}$/.test(s.token_hash)&&!s.token),'directory exposes only token hashes');
 // Non-owner management is refused before any store call.
 const editor=await (await new Peer(1).connect()).ready();
 check(editor.welcome.role==='editor','second principal keeps configured editor role');
 check((await editor.account('list')).code==='PERMISSION_DENIED','editor cannot use account management');
 const observer=await (await new Peer(2).connect()).ready();
 check((await observer.account('create',{name:'intruder',role:'observer'})).code==='PERMISSION_DENIED','observer cannot create accounts');observer.close();
 // Owner creates an account and issues a session; the cleartext token appears once.
 const created=await owner.account('create',{name:'agent-1',role:'editor'});
 check(created.ok&&created.data.account.role==='editor','owner creates editor account');
 const accountId=created.data.account.id;
 check(!(await owner.account('create',{name:'agent-1',role:'editor'})).ok,'duplicate account name refused');
 const issued=await owner.account('issue',{account_id:accountId,ttl_ms:3600000});
 check(issued.ok&&/^[a-f0-9]{64}$/.test(issued.data.token),'owner issues session token');
 const token=issued.data.token;
 // The issued token authenticates a brand-new connection.
 let agent=await (await new Peer(0).connect(token)).ready();
 check(agent.welcome.principal_id===accountId&&agent.welcome.role==='editor','issued token authenticates as the new account');
 // Revocation by token disconnects the live session within a frame and bars return.
 const revoked=await owner.account('revoke',{token});
 check(revoked.ok&&revoked.data.revoked===1,'owner revokes session by token');
 await until(()=>agent.closed);
 check(agent.closeCode===1008&&agent.closeReason==='SESSION_REVOKED','live client kicked on revocation');
 const returning=await new Peer(0).connect(token);await until(()=>returning.closed);
 check(!returning.state&&!returning.welcome,'revoked token cannot reconnect');
 // Disabling revokes every live session atomically and blocks new issues.
 const second=await owner.account('issue',{account_id:accountId,ttl_ms:3600000});
 agent=await (await new Peer(0).connect(second.data.token)).ready();
 const disabled=await owner.account('disable',{account_id:accountId});
 check(disabled.ok&&disabled.data.disabled===true,'owner disables account');
 await until(()=>agent.closed);
 check(agent.closeCode===1008&&agent.closeReason==='SESSION_REVOKED','disabling kicks the live client');
 check((await owner.account('issue',{account_id:accountId,ttl_ms:3600000})).code==='ACCOUNT_DISABLED','disabled account cannot receive sessions');
 const blocked=await new Peer(0).connect(second.data.token);await until(()=>blocked.closed);
 check(!blocked.state,'disabled account token stays rejected');
 // Re-enable never resurrects old sessions; a fresh issue works.
 check((await owner.account('enable',{account_id:accountId})).ok,'owner re-enables account');
 const third=await owner.account('issue',{account_id:accountId,ttl_ms:3600000});
 check(third.ok,'re-enabled account receives a new session');
 agent=await (await new Peer(0).connect(third.data.token)).ready();
 check(agent.welcome.principal_id===accountId,'new session authenticates after re-enable');agent.close();
 // Malformed management packets fail explicitly.
 check((await owner.account('frobnicate')).code==='UNSUPPORTED_ACCOUNT_ACTION','unknown action refused');
 check((await owner.account('create',{name:'x'})).code==='INVALID_ACCOUNT_REQUEST','missing role refused');
 check((await owner.account('issue',{account_id:crypto.randomUUID(),ttl_ms:3600000})).code==='ACCOUNT_NOT_FOUND','issue for unknown account refused');
 check((await owner.account('revoke',{token,account_id:accountId})).code==='INVALID_ACCOUNT_REQUEST','ambiguous revoke refused');
 // Audit trail records the whole lifecycle.
 const audit=await owner.account('audit',{limit:200});
 const actions=audit.data.audit.map(row=>row[2]);
 check(audit.ok&&actions.includes('account_create')&&actions.includes('session_issue')&&actions.includes('session_revoke')&&actions.includes('account_disable'),'audit log covers the identity lifecycle');
 editor.close();
 // Restart: accounts and sessions survive; the third token still authenticates.
 owner.close();await stop(server);await startServer();
 const owner2=await (await new Peer(0).connect()).ready();
 check((await owner2.account('list')).data.accounts.length===config.principals.length+1,'accounts persist across authority restart');
 const revived=await (await new Peer(0).connect(third.data.token)).ready();
 check(revived.welcome.principal_id===accountId,'issued session survives authority restart');
 revived.close();owner2.close();
 for(const name of ['authority-1.engine.log','authority-2.engine.log']){
  const log=fs.readFileSync(path.join(output,name),'utf8');
  check(!/SCRIPT ERROR|Parse Error/i.test(log),'no authority script errors: '+name);
 }
 await stop(gateway);await stop(server);
}
run().catch(async error=>{console.error(error);for(const child of children)await stop(child);process.exitCode=1});
