-- RCE e RET aceitam até 3 medicamentos (decisão do prescritor, 30/09/2026): o conteúdo guarda `medicamentos` (lista).
-- As notificações continuam com `medicamento`. O histórico mostra o primeiro e quantos mais há ("Amoxicilina + 1").
create or replace function cockpit_rx.receitas(p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object(
    'lista', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'estado', estado, 'numero', numero,
               'paciente', conteudo #>> '{paciente,nome}',
               'medicamento', coalesce(conteudo #>> '{medicamento,nome}',
                 (conteudo #>> '{medicamentos,0,nome}') || case when jsonb_array_length(conteudo -> 'medicamentos') > 1
                   then ' + ' || (jsonb_array_length(conteudo -> 'medicamentos') - 1) else '' end),
               'criadaEm', criada_em, 'emitidaEm', emitida_em, 'motivo', motivo, 'hash', conteudo_sha256,
               'codigo', case when estado = 'emitida' then acesso_codigo end) order by criada_em desc)
      from (select * from receita where prescritor_id = p_prescritor and not (estado = 'cancelada' and numero is null)
             order by criada_em desc limit 50) r), '[]'::jsonb),
    'emitente', (select conteudo -> 'emitente' from receita where prescritor_id = p_prescritor order by criada_em desc limit 1))
$$;
