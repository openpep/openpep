-- Fixa search_path das funções auxiliares (alerta function_search_path_mutable do Supabase).
alter function cockpit_rx.auditar() set search_path = cockpit_rx, pg_temp;
alter function cockpit_rx.somente_inclusao() set search_path = cockpit_rx, pg_temp;
alter function cockpit_rx.validar_numero() set search_path = cockpit_rx, pg_temp;
alter function cockpit_rx.dia_sncr(timestamptz) set search_path = cockpit_rx, pg_temp;
