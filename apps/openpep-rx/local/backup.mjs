// SPDX-License-Identifier: AGPL-3.0-or-later
import {DatabaseSync,backup} from 'node:sqlite';
import {existsSync,mkdirSync,chmodSync,renameSync,readdirSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {dataDirectory} from './database.mjs';
// Keeps the newest KEEP startup copies; older ones are removed after a verified new copy exists.
export const KEEP=30;
export async function backupDatabase(directory=dataDirectory(),{keep=KEEP}={}){
  const source=join(directory,'openpep-rx.sqlite');if(!existsSync(source))return null;
  const folder=join(directory,'backups');mkdirSync(folder,{recursive:true,mode:0o700});chmodSync(folder,0o700);
  const path=join(folder,'openpep-rx-'+new Date().toISOString().replaceAll(':','-')+'.sqlite'),temporary=path+'.tmp';
  const db=new DatabaseSync(source,{readOnly:true});try{await backup(db,temporary);}finally{db.close();}
  chmodSync(temporary,0o600);
  // Rollback-journal mode on the copy: verifying it leaves no -wal/-shm sidecars beside the backups.
  const check=new DatabaseSync(temporary);let valid;try{check.exec('PRAGMA journal_mode=DELETE');valid=Object.values(check.prepare('PRAGMA integrity_check').get())[0]==='ok';}finally{check.close();}
  if(!valid)throw Error('Não foi possível verificar a cópia de segurança. O banco original foi preservado.');
  renameSync(temporary,path);
  const copies=readdirSync(folder).filter(name=>/^openpep-rx-.+\.sqlite$/.test(name)).sort();
  for(const name of copies.slice(0,Math.max(0,copies.length-keep)))rmSync(join(folder,name));
  return path;
}
if(process.argv[1]===fileURLToPath(import.meta.url))console.log(await backupDatabase()||'Ainda não existe banco local para copiar.');
