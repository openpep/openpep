export const availableTypes=['NRA','NRB','NRB2','NRR','NRT','RCE','RET'];
export const restrictedTypes=[];

export function createStock(){return Object.fromEntries(availableTypes.map((type,i)=>[type,{next:i+1,available:3,released:[]}]));}

export function reserve(stock,type){
  if(!stock[type]||stock[type].available<1)return {stock,reservation:null};
  const item=stock[type],released=[...(item.released||[])],fromReleased=released.length>0;
  const number=fromReleased?released.shift():`SIM-${type}-${String(item.next).padStart(5,'0')}`;
  return {stock:{...stock,[type]:{...item,next:fromReleased?item.next:item.next+1,available:item.available-1,released}},reservation:{type,number}};
}

export function release(stock,reservation){
  if(!reservation||!stock[reservation.type])return stock;
  const item=stock[reservation.type],released=item.released||[];
  if(released.includes(reservation.number))return stock;
  return {...stock,[reservation.type]:{...item,available:item.available+1,released:[...released,reservation.number]}};
}

export function consume(state,documentId,reservation){
  if(state.consumed[documentId]||!reservation||state.consumedNumbers?.[reservation.number])return state;
  return {...state,consumed:{...state.consumed,[documentId]:reservation},consumedNumbers:{...state.consumedNumbers,[reservation.number]:documentId},history:[{action:'Consumo simulado',...reservation,documentId},...state.history]};
}

function period(date,unit){return unit==='day'?date.toISOString().slice(0,10):`${date.getUTCFullYear()}-${String(date.getUTCMonth()+1).padStart(2,'0')}`;}

export function requestBatch(state,type,quantity,now=new Date()){
  const date=now instanceof Date?now:new Date(now);
  const requests=state.requests||[],day=period(date,'day'),month=period(date,'month');
  const isNR=['NRA','NRB','NRB2','NRR','NRT'].includes(type);
  if(!Number.isInteger(quantity)||!state.stock?.[type])return {state,error:'Tipo ou quantidade demonstrativa inválida.'};
  if(isNR){
    const requested=requests.filter(r=>r.type===type&&r.day===day).reduce((sum,r)=>sum+r.quantity,0);
    if(quantity<10||quantity>50||requested+quantity>50)return {state,error:'Para notificações de receita, solicite de 10 a 50 números por tipo/dia; o total diário não pode passar de 50.'};
  }else if(!['RCE','RET'].includes(type)||quantity!==1000)return {state,error:'RCE e RET usam lote demonstrativo de 1000 números.'};
  else {
    const monthly=requests.filter(r=>r.type===type&&r.month===month);
    if(monthly.length>=3||monthly.reduce((sum,r)=>sum+r.quantity,0)+quantity>3000)return {state,error:'Cada tipo, RCE ou RET, permite no máximo três solicitações e 3000 números por mês.'};
  }
  const request={type,quantity,day,month},item=state.stock[type];
  return {state:{...state,stock:{...state.stock,[type]:{...item,available:item.available+quantity}},requests:[...requests,request],history:[{action:'Lote demonstrativo solicitado',type,number:`${quantity} números`,documentId:'—'},...state.history]},error:null};
}
