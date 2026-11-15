// Optional real, paid tool smoke. Open a voice session in the app first.
// This injects a backend text request on a trusted sideband; it is not a speech-recognition test.
import { readFileSync } from 'node:fs';
import { once } from 'node:events';
import WebSocket from 'ws';
import { configuration } from '../src/config.js';
const config = configuration();
const state=JSON.parse(readFileSync(new URL('../storage/state.json',import.meta.url),'utf8'));
const session=state.sessions.findLast(s=>s.state==='Active');
if(!session) throw new Error('Start a voice session in the app first');
const headers={Authorization:`Bearer ${config.token}`,'X-Client-ID':session.owner,'Content-Type':'application/json'};
const origin=`http://127.0.0.1:${config.port}`;
const baseline=new Set(state.tasks.map(t=>t.id));
const socket=new WebSocket(`wss://api.openai.com/v1/live/sessions/${encodeURIComponent(session.id)}/attach`,{headers:{Authorization:`Bearer ${config.apiKey}`}});
let observedCall=false;
const errors=[];
socket.on('message',raw=>{
 const e=JSON.parse(raw);
 if(e.type==='error') errors.push({code:e.error?.code,message:e.error?.message?.slice(0,200)});
 if(e.type==='response.event'&&e.event?.type==='response.output_item.done'&&e.event.item?.type==='function_call') observedCall=true;
});
socket.on('error',()=>{});
try {
 await once(socket,'open');
 socket.send(JSON.stringify({type:'response.item.create',item:{type:'message',role:'user',content:[{type:'input_text',text:'Я явно подтверждаю фоновое задание: подготовь краткий текстовый отчёт по моей базе знаний и позови меня по готовности. Зарегистрируй независимую задачу через enqueue_text_task. Заголовок: Проверка делегирования.'}]}}));
 socket.send(JSON.stringify({type:'response.create'}));
 const deadline=Date.now()+35000;
 let task;
 while(Date.now()<deadline){
  const r=await fetch(origin+'/tasks',{headers}); const b=await r.json();
  task=b.tasks?.find(t=>!baseline.has(t.id)&&t.conversation_id===session.conversation_id);
  if(task)break;
  if(errors.length)throw new Error(JSON.stringify(errors));
  await new Promise(r=>setTimeout(r,250));
 }
 if(!task||!observedCall)throw new Error('No real function call / durable task observed');
 console.log(JSON.stringify({type:'real_tool.passed',session_id:session.id,task_id:task.id,observed_function_call:observedCall}));
} finally {
 // This test explicitly requests End. Production never auto-closes on a queued task.
 const r=await fetch(origin+`/live/${session.id}/close`,{method:'POST',headers,body:'{}'});
 const closed=await r.json();
 console.log(JSON.stringify({type:'release.voice_closed',confirmed:closed.finalization_confirmed,usage:closed.usage}));
 socket.close();
}
