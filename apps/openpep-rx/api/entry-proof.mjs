import {normalizedCPF} from './entry-oidc.mjs';
// Synthetic session budget for the prescription demonstration.
export const SESSION_SIGNATURES=20;
// Small ASCII PDF for an authentication challenge; never a medical document.
export function challengePDF(id,subjectHash,time){
 if(!/^[a-f0-9]{64}$/.test(id)||!/^[a-f0-9]{64}$/.test(subjectHash))throw Error('proof-input');
 const lines=['OpenPEP | Confirmacao de entrada','TESTE DE AUTENTICACAO - SEM CONTEUDO CLINICO','Este documento confirma o controle do certificado nesta entrada.', 'Nao e receita, atestado, autorizacao clinica ou contrato.', 'Identificador de uso unico:',id,'Vinculo institucional opaco:',subjectHash,'Criado em: '+new Date(time).toISOString()];
 const escape=s=>s.replace(/([\\()])/g,'\\$1');
 const content='BT /F1 12 Tf 48 770 Td '+lines.map((s,i)=>(i?'0 -26 Td ':'')+'('+escape(s)+') Tj').join('\n')+' ET';
 const objects=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>','<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',`<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`];
 let pdf='%PDF-1.4\n',offsets=[0];objects.forEach((o,i)=>{offsets.push(Buffer.byteLength(pdf));pdf+=`${i+1} 0 obj\n${o}\nendobj\n`;});const xref=Buffer.byteLength(pdf);pdf+=`xref\n0 ${offsets.length}\n0000000000 65535 f \n`+offsets.slice(1).map(o=>`${String(o).padStart(10,'0')} 00000 n \n`).join('')+`trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;return Buffer.from(pdf);
}
// check names the first rule that failed, so the log says why without carrying the report.
const unverified=check=>Object.assign(Error('certificate-unverified'),{check});
// The OpenAPI shows the report itself, but the HML verifier answered a list on 29/09/2026.
// A list is accepted only with exactly one item (one PDF, one signature); every rule still applies to it.
const single=v=>Array.isArray(v)?(v.length===1?v[0]:undefined):v;
export function verifiedCertificate(response,expectedCPF,nonce,now,{homologation=false}={}){
 const report=single(response);if(!report||typeof report!=='object')throw unverified('report');
 if(Array.isArray(report.signatureStatus)&&report.signatureStatus.length!==1)throw unverified('signature-count');
 const status=single(report.signatureStatus),chain=status?.chainStatus;
 // Sent as a form field; the verifier may echo it as a number or a string.
 if(report.nonce===undefined||report.nonce===null||String(report.nonce)!==String(nonce))throw unverified('nonce');
 if(report.signatureFormat!=='PADES')throw unverified('format');
 // Homologation only (decided 29/09/2026): the fixture timestamp authority is outside ICP-Brasil, so the overall
 // result may be VALID_WITH_ALERT. The signer's chain and certificate below must still be fully VALID.
 const alerted=homologation&&report.generalStatus==='VALID_WITH_ALERT';
 if(report.generalStatus!=='VALID'&&!alerted)throw unverified('general-status');
 if(chain?.status!=='VALID')throw unverified('chain-status');
 const leaves=Array.isArray(chain.certificateStatusList)?chain.certificateStatusList.filter(c=>c?.['@type']==='FinalCertificate'):[];
 if(leaves.length!==1)throw unverified('leaf-count');const leaf=leaves[0],info=leaf.certificateInfo;
 const cpf=normalizedCPF(leaf.cpf);if(!cpf)throw unverified('cpf-absent');if(cpf!==expectedCPF)throw Error('certificate-mismatch');
 const before=Date.parse(info?.validity?.notBefore),after=Date.parse(info?.validity?.notAfter),reference=Date.parse(status.verificationReference);
 if(leaf.status!=='VALID')throw unverified('leaf-status');
 if(leaf.pkiBrazil!==true)throw unverified('icp-brasil');
 if(leaf.revocationStatus)throw unverified('revocation');
 if(!Number.isFinite(before)||!Number.isFinite(after)||!Number.isFinite(reference))throw unverified('dates');
 if(before>now||after<=now||before>reference||after<=reference)throw unverified('validity');
 if(Math.abs(reference-now)>300000)throw unverified('reference-skew');
 if(typeof info.serial!=='string'||!info.serial||typeof info.hash!=='string'||!info.hash)throw unverified('certificate-info');
 return {serial:info.serial,providerHash:info.hash,verifiedAt:now,notAfter:after,...(alerted?{acceptedWithAlert:true}:{})};
}
// Shape of a verification report for logs: field names, enum values and the verifier's alert/error keys only.
// Free text, numbers, CPF, name, serial and hashes never leave; anything unexpected becomes 'other'.
export function reportShape(response,now){
 const word=v=>v===undefined?'absent':v===null?'null':typeof v==='string'&&/^[A-Za-z_]{1,40}$/.test(v)?v:typeof v==='boolean'?v:'other';
 const keys=v=>Array.isArray(v)?`array(${v.length})`:v&&typeof v==='object'?Object.keys(v).filter(k=>/^[A-Za-z@_]{1,40}$/.test(k)).slice(0,30):v===null?'null':typeof v;
 const codes=nodes=>[...new Set(nodes.flatMap(n=>['alertStatus','errorStatus'].flatMap(kind=>{const list=n?.[kind]?.keyDescriptionList;return Array.isArray(list)?list.map(k=>typeof k?.key==='string'&&/^[A-Za-z][A-Za-z0-9_.-]{0,79}$/.test(k.key)?`${kind.slice(0,-6)}:${k.key}`:`${kind.slice(0,-6)}:other`):[];})))].slice(0,20);
 const report=single(response),status=single(report?.signatureStatus),chain=status?.chainStatus,list=Array.isArray(chain?.certificateStatusList)?chain.certificateStatusList:[];
 const leaves=list.filter(c=>c?.['@type']==='FinalCertificate'),leaf=leaves[0],reference=Date.parse(status?.verificationReference);
 return {response:keys(response),keys:keys(report),statusKeys:keys(report?.signatureStatus),nonceType:typeof report?.nonce,format:word(report?.signatureFormat),general:word(report?.generalStatus),chain:word(chain?.status),referenceType:word(status?.verificationReferenceType),types:list.slice(0,10).map(c=>word(c?.['@type'])),leaves:leaves.length,
  leaf:leaf?{keys:keys(leaf),status:word(leaf.status),pkiBrazil:word(leaf.pkiBrazil),revocation:keys(leaf.revocationStatus),hasCPF:Boolean(normalizedCPF(leaf.cpf))}:null,
  codes:codes([report,status,chain,leaf]),referenceSkewSeconds:Number.isFinite(reference)?Math.round((reference-now)/1000):null};
}
