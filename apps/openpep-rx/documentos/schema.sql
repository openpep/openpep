CREATE TABLE documents(id TEXT PRIMARY KEY,publisher TEXT NOT NULL,access_hash TEXT NOT NULL,pdf_hash TEXT NOT NULL,object_key TEXT NOT NULL,bytes INTEGER NOT NULL,created_at INTEGER NOT NULL,revoked_at INTEGER);
CREATE TABLE document_validations(document_id TEXT PRIMARY KEY REFERENCES documents(id),token_hash TEXT NOT NULL,expires_at INTEGER NOT NULL);
