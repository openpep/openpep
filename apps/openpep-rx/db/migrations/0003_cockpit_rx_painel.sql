-- Etapa 2: cadastro do prescritor a partir do vínculo e painel "Meus números" (docs/SNCR-NUMEROS-FLUXO.md).

-- Garante o prescritor da conta SSO. Dados divergentes nunca sobrescrevem um vínculo existente.
create function cockpit_rx.garantir_prescritor(p_conta_hash text, p_cpf text, p_nome text, p_uf text, p_inscricao text) returns uuid
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare p prescritor;
begin
  for tentativa in 1..2 loop
    select * into p from prescritor where conta_hash = p_conta_hash;
    if found then
      if (p.cpf, p.uf, p.inscricao) is distinct from (p_cpf, p_uf, p_inscricao) then
        raise exception 'os dados informados diferem do vínculo registrado para esta conta' using errcode = 'P0001';
      end if;
      return p.id;
    end if;
    begin
      insert into prescritor (conta_hash, cpf, nome, uf, inscricao) values (p_conta_hash, p_cpf, p_nome, p_uf, p_inscricao)
      returning * into p;
      return p.id;
    exception when unique_violation then
      -- Mesma conta criada em paralelo: confere de novo. CPF ou inscrição de outra conta: recusa.
      if not exists (select 1 from prescritor where conta_hash = p_conta_hash) then
        raise exception 'CPF ou inscrição já vinculados a outra conta' using errcode = 'P0001';
      end if;
    end;
  end loop;
  raise exception 'não foi possível registrar o prescritor' using errcode = 'P0001';
end $$;

create function cockpit_rx.prescritor_por_conta(p_conta_hash text) returns uuid
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select id from prescritor where conta_hash = p_conta_hash
$$;

-- Painel: estoque por tipo, uso dos limites (hoje para NR, mês para RCE/RET) e últimos pedidos.
create function cockpit_rx.painel(p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object(
    'estoque', coalesce((select jsonb_agg(to_jsonb(e)) from estoque(p_prescritor) e), '[]'::jsonb),
    'limites', (
      select coalesce(jsonb_object_agg(t.tipo, jsonb_build_object(
        'periodo', case when t.tipo in ('RCE', 'RET') then 'mes' else 'dia' end,
        'usado', case when t.tipo in ('RCE', 'RET')
          then (select count(*) from solicitacao s where s.prescritor_id = p_prescritor and s.tipo = t.tipo
                  and s.estado in ('enviando', 'recebida', 'quarentena', 'ambigua')
                  and date_trunc('month', dia_sncr(s.enviada_em)) = date_trunc('month', dia_sncr(now())))
          else (select coalesce(sum(quantidade), 0) from solicitacao s where s.prescritor_id = p_prescritor and s.tipo = t.tipo
                  and s.estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and dia_sncr(s.enviada_em) = dia_sncr(now())) end,
        'maximo', case when t.tipo in ('RCE', 'RET') then 3 else 50 end)), '{}'::jsonb)
      from unnest(array['NRA', 'NRB', 'NRB2', 'NRR', 'NRT', 'RCE', 'RET']) as t(tipo)),
    'saldoSncr', (
      select coalesce(jsonb_object_agg(tipo, jsonb_build_object('saldo', saldo_sncr, 'em', concluida_em)), '{}'::jsonb)
      from (select distinct on (tipo) tipo, saldo_sncr, concluida_em from solicitacao
             where prescritor_id = p_prescritor and saldo_sncr is not null order by tipo, concluida_em desc) u),
    'solicitacoes', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'quantidade', quantidade, 'estado', estado, 'criadaEm', criada_em,
               'concluidaEm', concluida_em, 'http', http_status, 'mensagem', mensagem) order by criada_em desc)
      from (select * from solicitacao where prescritor_id = p_prescritor order by criada_em desc limit 20) r), '[]'::jsonb))
$$;

revoke all on function cockpit_rx.garantir_prescritor(text, text, text, text, text), cockpit_rx.prescritor_por_conta(text), cockpit_rx.painel(uuid) from public;
grant execute on function cockpit_rx.garantir_prescritor(text, text, text, text, text), cockpit_rx.prescritor_por_conta(text), cockpit_rx.painel(uuid)
  to cockpit_rx_app;
