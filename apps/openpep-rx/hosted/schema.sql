CREATE TABLE rx_relay (
  id TEXT PRIMARY KEY, local_id TEXT NOT NULL UNIQUE, user_id TEXT NOT NULL,
  prescriber TEXT NOT NULL, environment TEXT NOT NULL, type TEXT NOT NULL,
  quantity INTEGER NOT NULL, period TEXT NOT NULL, intent TEXT NOT NULL,
  state_hash TEXT UNIQUE, status TEXT NOT NULL, result_kind TEXT, result TEXT,
  created_at INTEGER NOT NULL, completed_at INTEGER
);
CREATE INDEX rx_relay_user ON rx_relay(user_id,created_at);
CREATE INDEX rx_relay_quota ON rx_relay(prescriber,environment,type,period);
CREATE TABLE rx_exports(id TEXT PRIMARY KEY REFERENCES rx_relay(id),destination TEXT NOT NULL,package TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE TABLE rx_export_numbers(environment TEXT NOT NULL,canonical TEXT NOT NULL,export_id TEXT NOT NULL REFERENCES rx_exports(id),PRIMARY KEY(environment,canonical));
