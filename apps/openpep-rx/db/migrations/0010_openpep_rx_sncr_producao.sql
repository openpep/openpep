-- OpenPEP-Rx: SNCR de produção, RCE/RET e limites no horário de Brasília.
-- Mantém as autorizações administrativas e a separação dos registros anteriores.
alter table cockpit_rx.producao_solicitacao drop constraint producao_solicitacao_tipo_check;
alter table cockpit_rx.producao_solicitacao add constraint producao_solicitacao_tipo_check
  check (tipo in ('NRA', 'NRB', 'NRB2', 'NRR', 'NRT', 'RCE', 'RET'));
alter table cockpit_rx.producao_solicitacao drop constraint producao_solicitacao_check;
alter table cockpit_rx.producao_solicitacao add constraint producao_solicitacao_check
  check ((tipo in ('RCE', 'RET') and quantidade = 1000 and cnpj is not null)
    or (tipo not in ('RCE', 'RET') and quantidade between 10 and 50 and cnpj is null));

create or replace function cockpit_rx.producao_preparar(p_prescritor uuid, p_tipo text, p_quantidade int, p_cnpj text, p_chave text) returns uuid
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare p prescritor; existente uuid; novo uuid;
begin
  select id into existente from producao_solicitacao where chave = p_chave;
  if found then return existente; end if;
  select * into p from prescritor where id = p_prescritor;
  if not found or not exists (select 1 from producao_autorizado a where a.cpf = p.cpf and a.conselho = p.conselho and a.uf = p.uf and a.inscricao = p.inscricao) then
    raise exception 'prescritor não liberado para pedidos de produção' using errcode = 'P0001';
  end if;
  perform 1 from prescritor where id = p_prescritor for update;
  update producao_solicitacao set estado = 'descartada', concluida_em = now(), motivo = 'login não concluído'
   where prescritor_id = p_prescritor and estado = 'preparada' and criada_em < now() - interval '10 minutes';
  if exists (select 1 from producao_solicitacao where prescritor_id = p_prescritor and estado in ('preparada', 'enviando')) then
    raise exception 'já há um pedido de produção em andamento; confira o resultado antes de pedir de novo' using errcode = 'P0001';
  end if;
  if p_tipo in ('RCE', 'RET') and (select count(*) from producao_solicitacao where prescritor_id = p_prescritor and tipo = p_tipo
      and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and date_trunc('month', dia_sncr(criada_em)) = date_trunc('month', dia_sncr(now()))) >= 3 then
    raise exception 'limite de 3 pedidos de % no mês atingido', p_tipo using errcode = 'P0001';
  end if;
  if p_tipo in ('NRA', 'NRB', 'NRB2', 'NRR', 'NRT') and p_quantidade +
      coalesce((select sum(quantidade) from producao_solicitacao where prescritor_id = p_prescritor and tipo = p_tipo
        and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and dia_sncr(criada_em) = dia_sncr(now())), 0) > 50 then
    raise exception 'limite diário de 50 números de % atingido', p_tipo using errcode = 'P0001';
  end if;
  insert into producao_solicitacao (chave, prescritor_id, tipo, quantidade, cnpj) values (p_chave, p_prescritor, p_tipo, p_quantidade, p_cnpj)
  returning id into novo;
  return novo;
end $$;

create or replace function cockpit_rx.producao_painel(p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object(
    'liberado', exists (select 1 from prescritor p join producao_autorizado a on a.cpf = p.cpf and a.conselho = p.conselho and a.uf = p.uf and a.inscricao = p.inscricao where p.id = p_prescritor),
    'rceNoMes', (select count(*) from producao_solicitacao where prescritor_id = p_prescritor and tipo = 'RCE'
      and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and date_trunc('month', dia_sncr(criada_em)) = date_trunc('month', dia_sncr(now()))),
    'retNoMes', (select count(*) from producao_solicitacao where prescritor_id = p_prescritor and tipo = 'RET'
      and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and date_trunc('month', dia_sncr(criada_em)) = date_trunc('month', dia_sncr(now()))),
    'solicitacoes', coalesce((select jsonb_agg(x order by x.criada_em desc) from (
      select id, tipo, quantidade, estado, http, mensagem, motivo, criada_em, concluida_em,
             numeros[1] as primeiro, numeros[cardinality(numeros)] as ultimo, cardinality(numeros) as recebidos
        from producao_solicitacao where prescritor_id = p_prescritor order by criada_em desc limit 20) x), '[]'::jsonb))
$$;
