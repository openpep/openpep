-- Pedidos de números ao SNCR de PRODUÇÃO (decisão do usuário em 30/09/2026): só para prescritores liberados em
-- producao_autorizado, que só é preenchida manualmente no banco, nunca pela aplicação.
-- Tipos aceitos: RCE, com CNPJ da plataforma e 1000 números, e notificações, de 10 a 50.
-- Tabela separada do registro de homologação: os números de produção não entram em estoque, reserva nem emissão.
-- Aqui só se registra o pedido e se preserva a resposta. O pedido sai pela função Edge (o Cloudflare de produção
-- bloqueia a saída Node); a resposta completa passa pela área de resgate do Redis e é gravada aqui pela função Node.

create table cockpit_rx.producao_autorizado (
  cpf text primary key check (cpf ~ '^[0-9]{11}$'),
  conselho text not null default 'CRM' check (conselho in ('CRM', 'CRMV', 'CRO')),
  uf text not null check (uf ~ '^[A-Z]{2}$'),
  inscricao text not null check (inscricao ~ '^[1-9][0-9]{0,7}$'),
  autorizado_em timestamptz not null default now(),
  nota text
);

create table cockpit_rx.producao_solicitacao (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique check (char_length(chave) between 16 and 128),
  prescritor_id uuid not null references cockpit_rx.prescritor (id),
  tipo text not null check (tipo in ('NRA', 'NRB', 'NRB2', 'NRR', 'NRT', 'RCE')),
  quantidade int not null,
  cnpj text check (cnpj ~ '^[0-9]{14}$'),
  estado text not null default 'preparada'
    check (estado in ('preparada', 'enviando', 'recebida', 'quarentena', 'ambigua', 'recusada', 'descartada')),
  http int,
  corpo jsonb,
  mensagem text,
  motivo text,
  numeros text[],
  criada_em timestamptz not null default now(),
  enviada_em timestamptz,
  concluida_em timestamptz,
  check ((tipo = 'RCE' and quantidade = 1000 and cnpj is not null) or (tipo <> 'RCE' and quantidade between 10 and 50 and cnpj is null)),
  check (estado <> 'recebida' or cardinality(numeros) between 1 and 1000)
);
create index producao_solicitacao_prescritor on cockpit_rx.producao_solicitacao (prescritor_id, criada_em desc);

-- Estados finais não mudam; identidade do pedido é imutável; nada é excluído.
create function cockpit_rx.validar_producao() returns trigger language plpgsql as $$
begin
  if (new.id, new.chave, new.prescritor_id, new.tipo, new.quantidade, new.cnpj, new.criada_em)
     is distinct from (old.id, old.chave, old.prescritor_id, old.tipo, old.quantidade, old.cnpj, old.criada_em) then
    raise exception 'pedido de produção: identidade imutável' using errcode = 'P0001';
  end if;
  if old.estado in ('recebida', 'quarentena', 'recusada', 'descartada', 'ambigua') then
    raise exception 'pedido de produção já encerrado (%)', old.estado using errcode = 'P0001';
  end if;
  if not ((old.estado = 'preparada' and new.estado in ('enviando', 'descartada'))
       or (old.estado = 'enviando' and new.estado in ('recebida', 'quarentena', 'recusada', 'ambigua', 'descartada'))) then
    raise exception 'transição inválida: % -> %', old.estado, new.estado using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger producao_valida before update on cockpit_rx.producao_solicitacao for each row execute function cockpit_rx.validar_producao();
create trigger producao_sem_exclusao before delete on cockpit_rx.producao_solicitacao for each row execute function cockpit_rx.somente_inclusao();
create trigger producao_audita after insert or update on cockpit_rx.producao_solicitacao for each row execute function cockpit_rx.auditar();

-- Pedido novo. Recusa: prescritor não liberado ou com CPF/inscrição diferentes da liberação; pedido em andamento
-- (preparado há menos de 10 min ou em envio); RCE acima de 3 pedidos no mês (envio, recebido, quarentena ou
-- incerto contam como consumidos). Preparados antigos são descartados. A mesma chave devolve o mesmo pedido.
create function cockpit_rx.producao_preparar(p_prescritor uuid, p_tipo text, p_quantidade int, p_cnpj text, p_chave text) returns uuid
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
      and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and date_trunc('month', criada_em) = date_trunc('month', now())) >= 3 then
    raise exception 'limite de 3 pedidos de RCE no mês atingido' using errcode = 'P0001';
  end if;
  insert into producao_solicitacao (chave, prescritor_id, tipo, quantidade, cnpj) values (p_chave, p_prescritor, p_tipo, p_quantidade, p_cnpj)
  returning id into novo;
  return novo;
end $$;

-- Marca o envio antes de qualquer chamada ao SNCR. Falso: o pedido não está mais preparado.
create function cockpit_rx.producao_iniciar_envio(p_id uuid) returns boolean
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update producao_solicitacao set estado = 'enviando', enviada_em = now() where id = p_id and estado = 'preparada';
  return found;
end $$;

-- Grava o resultado de um pedido em envio. Idempotente: se já encerrado, devolve o estado atual sem mudar nada.
create function cockpit_rx.producao_registrar(p_id uuid, p_estado text, p_http int, p_corpo jsonb, p_mensagem text, p_numeros text[], p_motivo text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare atual text;
begin
  select estado into atual from producao_solicitacao where id = p_id for update;
  if not found then raise exception 'pedido de produção inexistente' using errcode = 'P0001'; end if;
  if atual <> 'enviando' then return atual; end if;
  update producao_solicitacao set estado = p_estado, http = p_http, corpo = p_corpo, mensagem = left(p_mensagem, 300),
         numeros = case when p_estado = 'recebida' then p_numeros end, motivo = left(p_motivo, 300), concluida_em = now()
   where id = p_id;
  return p_estado;
end $$;

-- Descarta um pedido preparado cujo login não foi concluído.
create function cockpit_rx.producao_descartar(p_id uuid) returns boolean
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update producao_solicitacao set estado = 'descartada', concluida_em = now(), motivo = 'login não concluído' where id = p_id and estado = 'preparada';
  return found;
end $$;

-- Painel de produção do prescritor: liberação e últimos 20 pedidos, com a primeira e a última numeração recebidas.
create function cockpit_rx.producao_painel(p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object(
    'liberado', exists (select 1 from prescritor p join producao_autorizado a on a.cpf = p.cpf and a.conselho = p.conselho and a.uf = p.uf and a.inscricao = p.inscricao where p.id = p_prescritor),
    'rceNoMes', (select count(*) from producao_solicitacao where prescritor_id = p_prescritor and tipo = 'RCE'
      and estado in ('enviando', 'recebida', 'quarentena', 'ambigua') and date_trunc('month', criada_em) = date_trunc('month', now())),
    'solicitacoes', coalesce((select jsonb_agg(x order by x.criada_em desc) from (
      select id, tipo, quantidade, estado, http, mensagem, motivo, criada_em, concluida_em,
             numeros[1] as primeiro, numeros[cardinality(numeros)] as ultimo, cardinality(numeros) as recebidos
        from producao_solicitacao where prescritor_id = p_prescritor order by criada_em desc limit 20) x), '[]'::jsonb))
$$;

-- Pedidos em envio (para concluir a partir da área de resgate).
create function cockpit_rx.producao_em_envio(p_prescritor uuid) returns setof uuid
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select id from producao_solicitacao where prescritor_id = p_prescritor and estado = 'enviando' order by criada_em
$$;

revoke all on function cockpit_rx.validar_producao(), cockpit_rx.producao_preparar(uuid, text, int, text, text), cockpit_rx.producao_iniciar_envio(uuid),
  cockpit_rx.producao_registrar(uuid, text, int, jsonb, text, text[], text), cockpit_rx.producao_descartar(uuid), cockpit_rx.producao_painel(uuid),
  cockpit_rx.producao_em_envio(uuid) from public;
grant execute on function cockpit_rx.producao_preparar(uuid, text, int, text, text), cockpit_rx.producao_iniciar_envio(uuid),
  cockpit_rx.producao_registrar(uuid, text, int, jsonb, text, text[], text), cockpit_rx.producao_descartar(uuid), cockpit_rx.producao_painel(uuid),
  cockpit_rx.producao_em_envio(uuid) to cockpit_rx_app;

alter table cockpit_rx.producao_autorizado enable row level security;
alter table cockpit_rx.producao_solicitacao enable row level security;
