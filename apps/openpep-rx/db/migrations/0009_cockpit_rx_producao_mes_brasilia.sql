-- O limite mensal de RCE em produção conta o mês no horário de Brasília (dia_sncr), como o registro de homologação
-- (0003). A 0008 contava em UTC: das 21h às 24h do último dia, um pedido entrava no mês seguinte.
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
  if p_tipo = 'RCE' and (select count(*) from producao_solicitacao where prescritor_id = p_prescritor and tipo = 'RCE'
      and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and date_trunc('month', dia_sncr(criada_em)) = date_trunc('month', dia_sncr(now()))) >= 3 then
    raise exception 'limite de 3 pedidos de RCE no mês atingido' using errcode = 'P0001';
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
    'solicitacoes', coalesce((select jsonb_agg(x order by x.criada_em desc) from (
      select id, tipo, quantidade, estado, http, mensagem, motivo, criada_em, concluida_em,
             numeros[1] as primeiro, numeros[cardinality(numeros)] as ultimo, cardinality(numeros) as recebidos
        from producao_solicitacao where prescritor_id = p_prescritor order by criada_em desc limit 20) x), '[]'::jsonb))
$$;
