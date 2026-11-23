import test from 'node:test';
import assert from 'node:assert/strict';
import{createStock,reserve,release,consume,requestBatch}from'../domain.js';

const day=new Date('2026-09-19T12:00:00Z');
const month=new Date('2026-09-20T12:00:00Z');
function state(){return {stock:createStock(),consumed:{},history:[]};}

test('reservas simultâneas recebem números distintos e cancelar devolve a mesma identidade uma vez',()=>{
  const start=createStock(),first=reserve(start,'NRA'),second=reserve(first.stock,'NRA');
  assert.notEqual(first.reservation.number,second.reservation.number);
  const released=release(first.stock,first.reservation);
  assert.equal(release(released,first.reservation).NRA.available,released.NRA.available);
  assert.equal(reserve(released,'NRA').reservation.number,first.reservation.number);
});

test('consumo é idempotente por documento e por número',()=>{
  let s=state(),r=reserve(s.stock,'NRA');s={...s,stock:r.stock};
  const consumed=consume(s,'doc-1',r.reservation);
  assert.strictEqual(consume(consumed,'doc-1',r.reservation),consumed);
  assert.strictEqual(consume(consumed,'doc-2',r.reservation),consumed);
  assert.equal(consumed.history.length,1);
});

test('notificação exige inteiro de 10 a 50 e soma no máximo 50 por tipo/dia',()=>{
  let s=state();
  assert.ok(requestBatch(s,'NRA',10.5,day).error);
  assert.ok(requestBatch(s,'NRA',9,day).error);
  s=requestBatch(s,'NRA',30,day).state;
  assert.ok(requestBatch(s,'NRA',21,day).error);
  assert.equal(requestBatch(s,'NRB',50,day).error,null);
});

test('contador de notificação é independente de estoque, consumo e dia anterior',()=>{
  let s=state();s=requestBatch(s,'NRR',50,day).state;
  s.consumed={'doc':{type:'NRR',number:'SIM-NRR-00001'}};
  assert.ok(requestBatch(s,'NRR',10,day).error);
  assert.equal(requestBatch(s,'NRR',10,new Date('2026-09-20T12:00:00Z')).error,null);
});

test('RCE e RET têm três lotes e 3000 números mensais por tipo conforme edição3',()=>{
  let s=state();
  assert.ok(requestBatch(s,'RCE',999,day).error);
  for(const type of ['RCE','RET']){
    for(let i=0;i<3;i++){
      const batch=requestBatch(s,type,1000,day);assert.equal(batch.error,null);s=batch.state;
    }
    assert.ok(requestBatch(s,type,1000,month).error);
    assert.equal(requestBatch(s,type,1000,new Date('2026-10-01T12:00:00Z')).error,null);
  }
  assert.equal(s.requests.length,6);
});
