// SPDX-License-Identifier: AGPL-3.0-or-later
import {DatabaseSync,backup} from 'node:sqlite';
import {existsSync,mkdirSync,chmodSync,renameSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {dataDirectory} from './database.mjs';
export async function backupDatabase(directory=dataDirectory()){
  const source=join(directory,'openpep-rx.sqlite');if(!existsSync(source))return null;
  const folder=join(directory,'backups');mkdirSync(folder,{recursive:true,mode:0o700});chmodSync(folder,0o700);
  const path=join(folder,'openpep-rx-'+new Date().toISOString().replaceAll(':','-')+'.sqlite'),temporary=path+'.tmp';
  const db=new DatabaseSync(source,{readOnly:true});try{await backup(db,temporary);}finally{db.close();}
  chmodSync(temporary,0o600);
  const check=new DatabaseSync(temporary,{readOnly:true});let valid;try{valid=Object.values(check.prepare('PRAGMA integrity_check').get())[0]==='ok';}finally{check.close();}
  if(!valid)throw Error('Não foi possível verificar a cópia de segurança. O banco original foi preservado.');
  renameSync(temporary,path);return path;
}
if(process.argv[1]===fileURLToPath(import.meta.url))console.log(await backupDatabase()||'Ainda não existe banco local para copiar.');
