-- SPDX-License-Identifier: AGPL-3.0-or-later
CREATE TABLE IF NOT EXISTS rx_settings(name TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE IF NOT EXISTS rx_documents(
  id TEXT PRIMARY KEY, owner TEXT NOT NULL, type TEXT NOT NULL, environment TEXT NOT NULL CHECK(environment IN ('hmg','prd')),
  content TEXT NOT NULL, content_hash TEXT NOT NULL, profile TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('rascunho','revisao','assinando','pendente','assinada','cancelada')),
  number TEXT, prepared BLOB, pdf_hash TEXT, ticket TEXT, expires_at INTEGER, signable INTEGER NOT NULL DEFAULT 0,
  signed_pdf BLOB, signed_hash TEXT, certificate TEXT, created_at INTEGER NOT NULL, signed_at INTEGER, cancel_reason TEXT, attempted_at INTEGER
) STRICT;
CREATE TABLE IF NOT EXISTS rx_requests(
  id TEXT PRIMARY KEY, owner TEXT NOT NULL, environment TEXT NOT NULL CHECK(environment IN ('hmg','prd')),
  type TEXT NOT NULL CHECK(type IN ('NRA','NRB','NRB2','NRR','NRT','RCE','RET')), quantity INTEGER NOT NULL,
  request TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('aguardando','enviando','recebido','recusado','nao-enviado','incerto','quarentena')),
  state_hash TEXT UNIQUE, period TEXT NOT NULL, created_at INTEGER NOT NULL, response TEXT, http INTEGER, message TEXT
) STRICT;
CREATE TABLE IF NOT EXISTS rx_numbers(
  environment TEXT NOT NULL, number TEXT NOT NULL, canonical TEXT NOT NULL, type TEXT NOT NULL, owner TEXT NOT NULL,
  request_id TEXT NOT NULL REFERENCES rx_requests(id), document_id TEXT UNIQUE REFERENCES rx_documents(id),
  status TEXT NOT NULL CHECK(status IN ('disponivel','reservado','utilizado','inutilizado')), received_at INTEGER NOT NULL,
  PRIMARY KEY(environment,number), UNIQUE(environment,canonical)
) STRICT;
CREATE INDEX IF NOT EXISTS rx_stock ON rx_numbers(owner,environment,type,status);
PRAGMA user_version=2;
CREATE TABLE IF NOT EXISTS rx_publications(document_id TEXT PRIMARY KEY,origin TEXT NOT NULL,link_token TEXT NOT NULL,pdf_hash TEXT,status TEXT NOT NULL CHECK(status IN ('pendente','publicado','revogado')),last_error TEXT,updated_at INTEGER NOT NULL) STRICT;

CREATE TABLE IF NOT EXISTS rx_signed_files (
  id TEXT PRIMARY KEY,
  pdf BLOB NOT NULL,
  hash TEXT NOT NULL,
  created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS rx_document_contacts (
  document_id TEXT PRIMARY KEY REFERENCES rx_documents(id),
  phone TEXT NOT NULL, email TEXT NOT NULL, updated_at INTEGER NOT NULL
) STRICT;
