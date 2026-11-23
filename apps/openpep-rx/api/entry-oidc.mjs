import * as oidc from 'openid-client';
import {ORIGIN} from './origin.mjs';
export const SSO_CALLBACK=ORIGIN+'/api/entrada/callback';
const stageLabels={configuration:'configuração do SSO',callback:'retorno do login',token:'troca do código pelo token',jwks:'consulta das chaves do provedor','id-token':'validação do token de identidade',userinfo:'consulta da identidade institucional',storage:'gravação da sessão'};
const reasons=new Set(['unknown','network','timeout','http','forbidden','invalid-client','invalid-grant','invalid-scope','access-denied','login-required','consent-required','unauthorized-client','claim','timestamp','key-selection','invalid-response','invalid-json','unsupported','subject']);
const claims=new Set(['iss','aud','nonce','auth_time','exp','nbf','iat','azp','sub']);
const oauthReasons={invalid_client:'invalid-client',invalid_grant:'invalid-grant',invalid_scope:'invalid-scope',access_denied:'access-denied',login_required:'login-required',consent_required:'consent-required',unauthorized_client:'unauthorized-client'};
const codeReasons={OAUTH_JWT_CLAIM_COMPARISON_FAILED:'claim',OAUTH_JWT_TIMESTAMP_CHECK_FAILED:'timestamp',OAUTH_KEY_SELECTION_FAILED:'key-selection',OAUTH_INVALID_RESPONSE:'invalid-response',OAUTH_RESPONSE_IS_NOT_CONFORM:'invalid-response',OAUTH_JSON_ATTRIBUTE_COMPARISON_FAILED:'claim',OAUTH_RESPONSE_IS_NOT_JSON:'invalid-json',OAUTH_PARSE_ERROR:'invalid-json',OAUTH_UNSUPPORTED_OPERATION:'unsupported',OAUTH_TIMEOUT:'timeout'};
// Only application-owned categories escape the OIDC boundary. Never retain cause/claims.
export class SSOFailure extends Error {
 constructor(stage,reason='unknown',httpStatus,claim){
  super(reason==='forbidden'?'sso-forbidden':'sso-failed');
  this.diagnostic={stage:Object.hasOwn(stageLabels,stage)?stage:'callback',reason:reasons.has(reason)?reason:'unknown'};
  if(Number.isInteger(httpStatus)&&httpStatus>=100&&httpStatus<=599)this.diagnostic.httpStatus=httpStatus;
  if(claims.has(claim))this.diagnostic.claim=claim;
 }
}
export function ssoDiagnostic(error,fallback='callback'){
 if(error instanceof SSOFailure){const d=error.diagnostic;return new SSOFailure(d.stage,d.reason,d.httpStatus,d.claim).diagnostic;}
 return new SSOFailure(fallback).diagnostic;
}
export function ssoFailureMessage(d){
 const safe=new SSOFailure(d.stage,d.reason,d.httpStatus,d.claim).diagnostic;
 const code=[safe.stage,safe.reason,safe.claim].filter(Boolean).join('/');
 return `Não foi possível concluir a ${stageLabels[safe.stage]}${safe.httpStatus?` (HTTP ${safe.httpStatus})`:''}. Encerre a sessão e inicie novamente. Diagnóstico: ${code}.`;
}
function classifiedFailure(error,phase,httpStatus,networkReason,requestPhase){
 let reason=networkReason||(httpStatus>=400?'http':'unknown'),claim;
 // Library error chains may contain sensitive bodies. Read only finite codes and claim names.
 for(let e=error,i=0;e&&typeof e==='object'&&i<5;e=e.cause,i++){
  if(Object.hasOwn(oauthReasons,e.error))reason=oauthReasons[e.error];
  else if(Object.hasOwn(codeReasons,e.code))reason=codeReasons[e.code];
  if(claims.has(e.claim))claim=e.claim;
 }
 if(httpStatus===403)reason='forbidden';
 if(reason==='invalid-json')phase=requestPhase;
 if(reason==='key-selection')phase='jwks';
 return new SSOFailure(phase,reason,httpStatus,claim);
}
export function ssoSettings(env=process.env){
 const token=new URL(env.SSO_URL_TOKEN?.trim()), info=new URL(env.SSO_URL_INFO?.trim());
 // Every installation pins its Keycloak realm explicitly; there is no default trusted issuer.
 const issuer = token.href.replace(/\/protocol\/openid-connect\/token$/, '');
 const trusted = Boolean(env.SSO_ISSUER?.trim()) && issuer === env.SSO_ISSUER.trim() && info.href === issuer + '/protocol/openid-connect/userinfo';
 if(token.protocol!=='https:'||info.protocol!=='https:'||token.username||token.password||info.username||info.password||token.search||info.search||token.hash||info.hash||token.origin!==info.origin||!trusted||!token.pathname.endsWith('/protocol/openid-connect/token')||!env.SSO_CLIENT_ID?.trim()||!env.SSO_CLIENT_SECRET?.trim())throw Error('sso-configuration');
 return {issuer,authorization:token.href.replace(/\/token$/,'/auth'),jwks:token.href.replace(/\/token$/,'/certs'),token:token.href,info:info.href,clientId:env.SSO_CLIENT_ID.trim(),secret:env.SSO_CLIENT_SECRET.trim()};
}
export function normalizedCPF(value){
 if(typeof value!=='string')return null;const s=value.replace(/[.\-\s]/g,'');
 if(!/^\d{11}$/.test(s)||/^(\d)\1{10}$/.test(s))return null;
 for(let len=9;len<11;len++){let sum=0;for(let i=0;i<len;i++)sum+=Number(s[i])*(len+1-i);let d=(sum*10)%11;if(d===10)d=0;if(d!==Number(s[len]))return null;}return s;
}
// Claim names only, never values: shows which fields the SSO sends when no CPF is resolved,
// and which of them hold a CPF-shaped value, so SSO_CPF_CLAIM can be chosen without seeing data.
export function claimSummary(claims,info){
 const names=o=>Object.keys(o||{}).filter(k=>/^[\w:.\-]{1,64}$/.test(k)).sort().slice(0,80);
 const single=v=>Array.isArray(v)&&v.length===1?v[0]:v;
 const cpfShaped=o=>names(o).filter(k=>{const v=single(o[k]);return normalizedCPF(typeof v==='number'?String(v).padStart(11,'0'):v)!==null;});
 const amr=Array.isArray(claims?.amr)?claims.amr.filter(v=>typeof v==='string'&&/^[\w.\-]{1,32}$/.test(v)).slice(0,10):null;
 return {event:'sso_claims',idToken:names(claims),userInfo:names(info),cpfShaped:{idToken:cpfShaped(claims),userInfo:cpfShaped(info)},amr};
}
export function makeOIDC(env=process.env,fetcher=fetch,log=event=>console.info(JSON.stringify(event))){
 const configured=()=>{try{ssoSettings(env);return true;}catch{return false;}};
 function configuration(){
  const s=ssoSettings(env);let phase='callback',requestPhase='callback',httpStatus,networkReason;
  const allowed=new Set([s.token,s.info,s.jwks]);
  const secureFetch=async(input,options)=>{
   const u=new URL(typeof input==='string'?input:input.url||input.href);
   if(!allowed.has(u.href))throw new SSOFailure('configuration');
   const headers=new Headers(options?.headers);headers.set('User-Agent','cockpit-rx/0.1');
   phase=u.href===s.token?'token':u.href===s.jwks?'jwks':'userinfo';requestPhase=phase;httpStatus=undefined;networkReason=undefined;
   let response;
   // 'manual', not 'error': the callback runs on Edge, whose fetch rejects redirect:'error'. Redirects are refused below.
   try{response=await fetcher(input,{...options,headers,redirect:'manual',signal:AbortSignal.timeout(15000)});}
   catch(e){networkReason=e?.name==='TimeoutError'?'timeout':'network';throw e;}
   httpStatus=response.status;
   if(response.status===403){await response.body?.cancel();throw Error('sso-forbidden');}
   if(response.type==='opaqueredirect'||(response.status>=300&&response.status<400)){await response.body?.cancel();throw Error('sso-redirect');}
   if(response.ok&&phase!=='userinfo')phase='id-token';
   return response;
  };
  // Explicit Keycloak endpoints; no discovery request before redirect.
  const config=new oidc.Configuration({issuer:s.issuer,authorization_endpoint:s.authorization,token_endpoint:s.token,userinfo_endpoint:s.info,jwks_uri:s.jwks,response_types_supported:['code'],id_token_signing_alg_values_supported:['RS256']},s.clientId,s.secret,oidc.ClientSecretPost(s.secret));
  config[oidc.customFetch]=secureFetch;
  oidc.enableNonRepudiationChecks(config);
  return {config,diagnose:error=>classifiedFailure(error,phase,httpStatus,networkReason,requestPhase)};
 }
 async function begin(state,nonce,verifier){
  const {config}=configuration();
  return oidc.buildAuthorizationUrl(config,{redirect_uri:SSO_CALLBACK,response_type:'code',scope:'openid profile',state,nonce,code_challenge:await oidc.calculatePKCECodeChallenge(verifier),code_challenge_method:'S256',max_age:'3600'}).href;
 }
 async function complete(url,attempt){
  let settings;try{settings=configuration();}catch{throw new SSOFailure('configuration');}
  const {config,diagnose}=settings;
  try {
  const tokens=await oidc.authorizationCodeGrant(config,new URL(url),{pkceCodeVerifier:attempt.verifier,expectedState:attempt.state,expectedNonce:attempt.nonce,idTokenExpected:true,maxAge:3600});
  const claims=tokens.claims();if(!claims?.sub)throw new SSOFailure('id-token','subject');
  const info=await oidc.fetchUserInfo(config,tokens.access_token,claims.sub);
  const cpfClaim=env.SSO_CPF_CLAIM?.trim();
  // UserInfo first, then the signed ID token: Keycloak mappers may place the attribute in either.
  const cpf=cpfClaim?normalizedCPF(info[cpfClaim]??claims[cpfClaim]):null;
  if(!cpf)try{log(claimSummary(claims,info));}catch{}
  const hasPasswordFactor=Array.isArray(claims.amr)&&claims.amr.includes('pwd');
  const acr=typeof claims.acr==='string'&&/^[\w.:\-]{1,64}$/.test(claims.acr)?claims.acr:null;
  return {subject:claims.sub,issuer:claims.iss,name:typeof info.name==='string'?info.name.slice(0,120):'Profissional',cpf,hasPasswordFactor,acr};
  }catch(e){throw e instanceof SSOFailure?e:diagnose(e);}
 }
 return {configured,begin,complete};
}
