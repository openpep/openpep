// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
export function normalizedCPF(value){
 if(typeof value!=='string')return null;const s=value.replace(/[.\-\s]/g,'');
 if(!/^\d{11}$/.test(s)||/^(\d)\1{10}$/.test(s))return null;
 for(let len=9;len<11;len++){let sum=0;for(let i=0;i<len;i++)sum+=Number(s[i])*(len+1-i);let d=(sum*10)%11;if(d===10)d=0;if(d!==Number(s[len]))return null;}return s;
}
