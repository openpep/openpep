import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
export function memoryD1(){
  const sql=new DatabaseSync(':memory:');sql.exec('PRAGMA foreign_keys=ON;');sql.exec(readFileSync(new URL('../hosted/schema.sql',import.meta.url),'utf8'));
  const DB={prepare(query){return {bind(...params){const stmt=sql.prepare(query);return {first:async()=>stmt.get(...params)||null,all:async()=>({results:stmt.all(...params)}),run:async()=>({meta:stmt.run(...params)}),execute:()=>({meta:stmt.run(...params)})};}};},async batch(statements){sql.exec('BEGIN IMMEDIATE');try{const results=statements.map(s=>s.execute());sql.exec('COMMIT');return results;}catch(e){sql.exec('ROLLBACK');throw e;}}};
  return {sql,DB};
}
