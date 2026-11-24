// SPDX-License-Identifier: AGPL-3.0-or-later
import {DatabaseSync} from 'node:sqlite';
import {mkdirSync, chmodSync, readFileSync, existsSync} from 'node:fs';
import {resolve, join} from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
import {NR_TYPES, RANGE_TYPES, parseNotificationResponse, expandRangeResponse} from '../api/ledger.mjs';

export const sha = value => createHash('sha256').update(value).digest('hex');
export const ownerOf = profile => sha(`${profile.cpf}|${profile.crm}|${profile.uf}`);
export function dataDirectory(env = process.env) {
  return resolve(env.OPENPEP_RX_DATA_DIR || (env.OPENPEP_DATA_DIR ? join(env.OPENPEP_DATA_DIR, 'prescricao') : './.local-data/prescricao'));
}

export class LocalDatabase {
  constructor(directory = ':memory:') {
    this.path = directory === ':memory:' ? directory : join(resolve(directory), 'openpep-rx.sqlite');
    if (directory !== ':memory:') mkdirSync(resolve(directory), {recursive: true, mode: 0o700});
    this.db = new DatabaseSync(this.path);
    if (directory !== ':memory:') chmodSync(this.path, 0o600);
    this.db.exec('PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;');
    // WAL sidecars follow the process umask; they hold the same clinical data as the database.
    if (directory !== ':memory:') for (const suffix of ['-wal', '-shm']) if (existsSync(this.path + suffix)) chmodSync(this.path + suffix, 0o600);
    this.db.exec(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
    if (!this.all('PRAGMA table_info(rx_documents)').some(c => c.name === 'attempted_at')) this.db.exec('ALTER TABLE rx_documents ADD COLUMN attempted_at INTEGER');
  }
  recoverInterrupted() { this.db.exec("UPDATE rx_documents SET status='pendente' WHERE status='assinando'; UPDATE rx_requests SET status='incerto' WHERE status='enviando';"); }
  close() { this.db.close(); }
  get(sql, ...args) { return this.db.prepare(sql).get(...args); }
  all(sql, ...args) { return this.db.prepare(sql).all(...args); }
  run(sql, ...args) { return this.db.prepare(sql).run(...args); }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = fn(); this.db.exec('COMMIT'); return value; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  setting(name, fallback = null) { const row = this.get('SELECT value FROM rx_settings WHERE name=?', name); return row ? JSON.parse(row.value) : fallback; }
  setSetting(name, value) { this.run('INSERT INTO rx_settings VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value', name, JSON.stringify(value)); }
  profile() { return this.setting('profile'); }
  config() { return this.setting('sncr', {enabled: false, environment: 'prd', cnpj: ''}); }
  stock(owner, environment) {
    return Object.fromEntries(this.all("SELECT type,COUNT(*) AS n FROM rx_numbers WHERE owner=? AND environment=? AND status='disponivel' GROUP BY type", owner, environment).map(r => [r.type, r.n]));
  }
  document(id, owner) { return this.get('SELECT * FROM rx_documents WHERE id=? AND owner=?', id, owner); }
  documents(owner) { return this.all('SELECT id,type,status,number,content_hash,content,created_at,signed_at FROM rx_documents WHERE owner=? ORDER BY created_at DESC LIMIT 200', owner); }
  contact(id) { return this.get('SELECT phone,email FROM rx_document_contacts WHERE document_id=?', id) || {phone:'',email:''}; }
  saveContact(id, contact) { this.run('INSERT INTO rx_document_contacts VALUES(?,?,?,?) ON CONFLICT(document_id) DO UPDATE SET phone=excluded.phone,email=excluded.email,updated_at=excluded.updated_at', id, contact.phone, contact.email, Date.now()); return this.contact(id); }
  saveDraft({id, owner, type, content, hash, profile, environment, contact}) {
    return this.transaction(() => {
      const existing = this.get('SELECT * FROM rx_documents WHERE id=?', id);
      if (existing && (existing.owner !== owner || existing.attempted_at !== null || !['rascunho', 'revisao'].includes(existing.status))) throw Error('Este documento não pode mais ser editado. Crie uma nova receita.');
      if (existing?.number && JSON.parse(existing.content)._practice !== content._practice) throw Error('Esta receita já tem número reservado. Crie outra receita para o ensaio.');
      if (existing?.number && (existing.type !== type || existing.environment !== environment)) throw Error('Esta receita já tem um número reservado. Cancele-a antes de trocar o modelo ou ambiente.');
      this.run(`INSERT INTO rx_documents (id,owner,type,content,content_hash,profile,environment,status,created_at)
        VALUES (?,?,?,?,?,?,?,'rascunho',?) ON CONFLICT(id) DO UPDATE SET type=excluded.type,content=excluded.content,
        content_hash=excluded.content_hash,profile=excluded.profile,environment=excluded.environment,status='rascunho',
        prepared=NULL,pdf_hash=NULL,ticket=NULL,expires_at=NULL`, id, owner, type, JSON.stringify(content), hash, JSON.stringify(profile), environment, Date.now());
      if (contact) this.saveContact(id, contact);
      return this.document(id, owner);
    });
  }
  reserve(id, owner) {
    return this.transaction(() => {
      const doc = this.document(id, owner);
      if (!doc || !['rascunho', 'revisao', 'pendente'].includes(doc.status)) throw Error('Receita indisponível para revisão.');
      if (doc.number) return doc.number;
      const row = this.get("SELECT number FROM rx_numbers WHERE owner=? AND environment=? AND type=? AND status='disponivel' ORDER BY received_at,number LIMIT 1", owner, doc.environment, doc.type);
      if (!row) return null;
      this.run("UPDATE rx_numbers SET status='reservado',document_id=? WHERE environment=? AND number=? AND status='disponivel'", id, doc.environment, row.number);
      this.run('UPDATE rx_documents SET number=? WHERE id=?', row.number, id);
      return row.number;
    });
  }
  review(id, owner, prepared, hash, ticket, expires, signable) {
    const change = this.run("UPDATE rx_documents SET prepared=?,pdf_hash=?,ticket=?,expires_at=?,status='revisao',signable=? WHERE id=? AND owner=? AND status IN ('rascunho','revisao','pendente')", prepared, hash, sha(ticket), expires, signable ? 1 : 0, id, owner);
    if (change.changes !== 1) throw Error('O documento mudou durante a revisão.');
  }
  claim(id, owner, ticket, hash, now) {
    return this.transaction(() => {
      const doc = this.document(id, owner);
      if (!doc || doc.status !== 'revisao' || !doc.signable || doc.ticket !== sha(ticket) || doc.pdf_hash !== hash || doc.expires_at <= now) throw Error('Revise novamente o PDF antes de autorizar a assinatura.');
      this.run("UPDATE rx_documents SET status='assinando',ticket=NULL,attempted_at=? WHERE id=?", now, id);
      if (doc.number) this.run("UPDATE rx_numbers SET status='utilizado' WHERE document_id=?", id);
      return doc;
    });
  }
  signed(id, pdf, certificate) {
    const change = this.run("UPDATE rx_documents SET status='assinada',signed_pdf=?,signed_hash=?,certificate=?,signed_at=? WHERE id=? AND status='assinando'", pdf, sha(pdf), certificate, Date.now(), id);
    if (change.changes !== 1) throw Error('Não foi possível registrar a assinatura.');
  }
  failed(id) { this.run("UPDATE rx_documents SET status='pendente',ticket=NULL WHERE id=? AND status='assinando'", id); }
  cancel(id, owner, reason) {
    return this.transaction(() => {
      const doc = this.document(id, owner);
      if (!doc || !['rascunho', 'revisao', 'pendente'].includes(doc.status)) throw Error('Este documento não pode ser cancelado.');
      this.run("UPDATE rx_documents SET status='cancelada',ticket=NULL,cancel_reason=? WHERE id=?", reason, id);
      this.run("UPDATE rx_numbers SET status='inutilizado' WHERE document_id=?", id);
    });
  }
  beginNumbers({owner, environment, type, quantity, request, state, now = Date.now()}) {
    return this.transaction(() => {
      this.run("UPDATE rx_requests SET status='nao-enviado',state_hash=NULL,message='Login não concluído no prazo; nenhum pedido enviado.' WHERE status='aguardando' AND created_at<?", now - 300_000);
      const day = new Date(now).toLocaleDateString('en-CA', {timeZone: 'America/Sao_Paulo'});
      const period = RANGE_TYPES.includes(type) ? day.slice(0, 7) : day;
      const rows = this.all("SELECT quantity FROM rx_requests WHERE owner=? AND environment=? AND type=? AND period=? AND status NOT IN ('recusado','nao-enviado')", owner, environment, type, period);
      if (RANGE_TYPES.includes(type) ? rows.length >= 3 : rows.reduce((sum, r) => sum + r.quantity, 0) + quantity > 50) throw Error('O limite local deste tipo e período já foi atingido, incluindo pedidos pendentes.');
      const id = randomUUID();
      this.run("INSERT INTO rx_requests (id,owner,environment,type,quantity,request,status,state_hash,period,created_at) VALUES (?,?,?,?,?,?,'aguardando',?,?,?)", id, owner, environment, type, quantity, JSON.stringify(request), sha(state), period, now);
      return id;
    });
  }
  claimNumbers(state, now) {
    return this.transaction(() => {
      const row = this.get("SELECT * FROM rx_requests WHERE state_hash=? AND status='aguardando'", sha(state));
      if (!row || now - row.created_at > 300_000 || now < row.created_at) throw Error('Retorno expirado ou já utilizado.');
      this.run("UPDATE rx_requests SET status='enviando',state_hash=NULL WHERE id=?", row.id);
      return row;
    });
  }
  recordNumbers(request, result) {
    // The raw response is committed before parsing; a crash cannot lose an issued range.
    this.run("UPDATE rx_requests SET response=?,http=?,status='incerto' WHERE id=?", JSON.stringify(result.body), result.http ?? null, request.id);
    return this.transaction(() => {
      let parsed, status = result.kind === 'refused' ? 'recusado' : result.kind === 'not-sent' ? 'nao-enviado' : 'incerto';
      if (result.kind === 'success') {
        parsed = NR_TYPES.includes(request.type) ? parseNotificationResponse(result.body, request.quantity) : expandRangeResponse(result.body, request.quantity);
        status = parsed.error ? 'quarentena' : 'recebido';
        if (!parsed.error && parsed.numbers.some(number => this.get('SELECT 1 FROM rx_numbers WHERE environment=? AND canonical=?', request.environment, number.replace(/[.-]/g, '')))) status = 'quarentena';
      }
      if (status === 'recebido') for (const number of parsed.numbers) this.run("INSERT INTO rx_numbers (environment,number,canonical,type,owner,request_id,status,received_at) VALUES (?,?,?,?,?,?,'disponivel',?)", request.environment, number, number.replace(/[.-]/g, ''), request.type, request.owner, request.id, Date.now());
      this.run('UPDATE rx_requests SET status=?,message=? WHERE id=?', status, parsed?.error || result.message || null, request.id);
      return status;
    });
  }
  summary(owner) {
    return {path: this.path, numbers: this.all('SELECT environment,type,status,COUNT(*) AS count FROM rx_numbers WHERE owner=? GROUP BY environment,type,status', owner),
      requests: this.all('SELECT id,environment,type,quantity,status,message,http,created_at FROM rx_requests WHERE owner=? ORDER BY created_at DESC LIMIT 100', owner),
      allocated: this.all('SELECT environment,number,type,status,document_id FROM rx_numbers WHERE owner=? ORDER BY received_at DESC,number LIMIT 500', owner)};
  }
}
