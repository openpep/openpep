-- cockpit-rx: registro de números SNCR. Plano: docs/SNCR-NUMERACAO-PLANO.md.
-- Postgres padrão (tabelas, restrições, gatilhos, PL/pgSQL), sem recursos exclusivos do Supabase,
-- para migrar depois ao Postgres institucional. A aplicação usa só as funções abaixo (papel cockpit_rx_app).

create schema if not exists cockpit_rx;
revoke all on schema cockpit_rx from public;

-- Prescritor = vínculo conta SSO ↔ CPF/CRM/UF (hoje no Redis; migra para cá).
create table cockpit_rx.prescritor (
  id uuid primary key default gen_random_uuid(),
  conta_hash text not null unique check (conta_hash ~ '^[a-f0-9]{64}$'), -- sha256(iss|sub)
  cpf text not null unique check (cpf ~ '^[0-9]{11}$'),
  nome text not null check (char_length(nome) between 5 and 120),
  conselho text not null default 'CRM' check (conselho in ('CRM', 'CRMV', 'CRO')),
  uf text not null check (uf ~ '^[A-Z]{2}$'),
  inscricao text not null check (inscricao ~ '^[1-9][0-9]{0,7}$'),
  certificado_serial text,
  vinculado_em timestamptz not null default now(),
  unique (conselho, uf, inscricao)
);

-- Um pedido ao SNCR. A intenção é gravada antes do envio; a resposta, antes de qualquer outra coisa.
create table cockpit_rx.solicitacao (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique check (char_length(chave) between 16 and 128), -- idempotência da intenção
  prescritor_id uuid not null references cockpit_rx.prescritor (id),
  tipo text not null check (tipo in ('NRA', 'NRB', 'NRB2', 'NRR', 'NRT', 'RCE', 'RET')),
  quantidade int not null,
  cnpj text,
  estado text not null default 'preparada'
    check (estado in ('preparada', 'enviando', 'recebida', 'quarentena', 'ambigua', 'recusada', 'descartada')),
  criada_em timestamptz not null default now(),
  enviada_em timestamptz,
  concluida_em timestamptz,
  http_status int,
  resposta jsonb, -- corpo exato da resposta do SNCR (números e mensagens; nunca o token)
  saldo_sncr int,
  mensagem text,
  check (
    (tipo in ('RCE', 'RET') and quantidade = 1000 and cnpj ~ '^[0-9]{14}$')
    or (tipo not in ('RCE', 'RET') and quantidade between 10 and 50 and cnpj is null)
  )
);
create index solicitacao_limites on cockpit_rx.solicitacao (prescritor_id, tipo, enviada_em);

-- Um número por linha. Nunca é apagado; estados só avançam.
create table cockpit_rx.numero (
  numero text primary key check (numero ~ '^[0-9][0-9.-]{0,39}$'),
  prescritor_id uuid not null references cockpit_rx.prescritor (id),
  tipo text not null check (tipo in ('NRA', 'NRB', 'NRB2', 'NRR', 'NRT', 'RCE', 'RET')),
  solicitacao_id uuid not null references cockpit_rx.solicitacao (id),
  sequencia bigint not null,
  recebido_em timestamptz not null default now(),
  estado text not null default 'disponivel' check (estado in ('disponivel', 'reservado', 'usado', 'inutilizado')),
  receita_id uuid,
  liberado boolean not null default false, -- o PDF com este número saiu do servidor (assinatura, download)
  reservado_em timestamptz,
  usado_em timestamptz,
  inutilizado_em timestamptz,
  pdf_sha256 text check (pdf_sha256 ~ '^[a-f0-9]{64}$'),
  motivo text,
  check (estado <> 'disponivel' or (receita_id is null and not liberado)),
  check (estado not in ('reservado', 'usado') or receita_id is not null),
  check (estado <> 'usado' or (pdf_sha256 is not null and liberado)),
  check (estado <> 'inutilizado' or char_length(motivo) between 3 and 300)
);
-- Uma receita tem no máximo um número por tipo; um número pertence a no máximo uma receita (PK).
create unique index numero_por_receita on cockpit_rx.numero (receita_id, tipo) where receita_id is not null;
create index numero_estoque on cockpit_rx.numero (prescritor_id, tipo, recebido_em, sequencia) where estado = 'disponivel';

-- Trilha de auditoria: só inclusão, alimentada por gatilhos (não depende da aplicação).
create table cockpit_rx.evento (
  id bigint generated always as identity primary key,
  em timestamptz not null default now(),
  entidade text not null,
  chave text not null,
  acao text not null,
  antes jsonb,
  depois jsonb
);

create function cockpit_rx.auditar() returns trigger language plpgsql as $$
declare linha jsonb := to_jsonb(new);
begin
  insert into cockpit_rx.evento (entidade, chave, acao, antes, depois)
  values (tg_table_name, coalesce(linha ->> 'numero', linha ->> 'id'), lower(tg_op),
          case when tg_op = 'UPDATE' then to_jsonb(old) end, linha);
  return new;
end $$;

create function cockpit_rx.somente_inclusao() returns trigger language plpgsql as $$
begin
  raise exception 'cockpit_rx.%: % não permitido', tg_table_name, tg_op using errcode = 'P0001';
end $$;

-- Transições válidas de um número; campos de identidade são imutáveis.
create function cockpit_rx.validar_numero() returns trigger language plpgsql as $$
begin
  if (new.numero, new.prescritor_id, new.tipo, new.solicitacao_id, new.sequencia, new.recebido_em)
     is distinct from (old.numero, old.prescritor_id, old.tipo, old.solicitacao_id, old.sequencia, old.recebido_em) then
    raise exception 'numero %: identidade imutável', old.numero using errcode = 'P0001';
  end if;
  if old.liberado and not new.liberado then
    raise exception 'numero %: liberação não pode ser desfeita', old.numero using errcode = 'P0001';
  end if;
  if old.estado <> new.estado and not (
       (old.estado = 'disponivel' and new.estado in ('reservado', 'inutilizado'))
    or (old.estado = 'reservado' and new.estado in ('usado', 'inutilizado'))
    or (old.estado = 'reservado' and new.estado = 'disponivel' and not old.liberado)
  ) then
    raise exception 'numero %: transição % -> % não permitida', old.numero, old.estado, new.estado using errcode = 'P0001';
  end if;
  if old.estado in ('usado', 'inutilizado') and row(new.*) is distinct from row(old.*) then
    raise exception 'numero %: estado final', old.numero using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger numero_valida before update on cockpit_rx.numero for each row execute function cockpit_rx.validar_numero();
create trigger numero_sem_exclusao before delete on cockpit_rx.numero for each row execute function cockpit_rx.somente_inclusao();
create trigger numero_audita after insert or update on cockpit_rx.numero for each row execute function cockpit_rx.auditar();
create trigger solicitacao_sem_exclusao before delete on cockpit_rx.solicitacao for each row execute function cockpit_rx.somente_inclusao();
create trigger solicitacao_audita after insert or update on cockpit_rx.solicitacao for each row execute function cockpit_rx.auditar();
create trigger prescritor_audita after insert or update on cockpit_rx.prescritor for each row execute function cockpit_rx.auditar();
create trigger evento_somente_inclusao before update or delete on cockpit_rx.evento for each row execute function cockpit_rx.somente_inclusao();

-- Dia e mês do SNCR em horário de Brasília.
create function cockpit_rx.dia_sncr(t timestamptz) returns date language sql stable as $$
  select (t at time zone 'America/Sao_Paulo')::date
$$;

-- 1. Intenção. Idempotente pela chave; confere os limites locais antes do login gov.br.
create function cockpit_rx.preparar_solicitacao(p_prescritor uuid, p_tipo text, p_quantidade int, p_cnpj text, p_chave text)
returns cockpit_rx.solicitacao language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare
  s solicitacao;
  hoje date := dia_sncr(now());
  usados int;
begin
  select * into s from solicitacao where chave = p_chave;
  if found then
    if (s.prescritor_id, s.tipo, s.quantidade, s.cnpj) is distinct from (p_prescritor, p_tipo, p_quantidade, p_cnpj) then
      raise exception 'chave de solicitação reutilizada com outros dados' using errcode = 'P0001';
    end if;
    return s;
  end if;
  -- Pedidos incertos contam no limite: podem ter sido atendidos.
  if p_tipo in ('RCE', 'RET') then
    select count(*) into usados from solicitacao
     where prescritor_id = p_prescritor and tipo = p_tipo and estado in ('enviando', 'recebida', 'quarentena', 'ambigua')
       and date_trunc('month', dia_sncr(enviada_em)) = date_trunc('month', hoje);
    if usados >= 3 then raise exception 'limite mensal de 3 solicitações de % atingido', p_tipo using errcode = 'P0001'; end if;
  else
    select coalesce(sum(quantidade), 0) into usados from solicitacao
     where prescritor_id = p_prescritor and tipo = p_tipo and estado in ('enviando', 'recebida', 'quarentena', 'ambigua')
       and dia_sncr(enviada_em) = hoje;
    if usados + p_quantidade > 50 then
      raise exception 'limite diário de 50 números de % excedido (já solicitados hoje: %)', p_tipo, usados using errcode = 'P0001';
    end if;
  end if;
  insert into solicitacao (prescritor_id, tipo, quantidade, cnpj, chave)
  values (p_prescritor, p_tipo, p_quantidade, p_cnpj, p_chave) returning * into s;
  return s;
end $$;

-- 2. Reivindica o envio: só uma chamada ao SNCR por intenção, nunca repetida.
create function cockpit_rx.iniciar_envio(p_id uuid) returns boolean
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update solicitacao set estado = 'enviando', enviada_em = now() where id = p_id and estado = 'preparada';
  return found;
end $$;

-- 3a. Resposta de sucesso já validada pela aplicação: números entram no estoque na mesma transação.
-- Se algum número já existir, o lote inteiro vai para quarentena (nada é alocado).
create function cockpit_rx.registrar_recebimento(p_id uuid, p_http int, p_resposta jsonb, p_numeros text[], p_sequencias bigint[], p_saldo int, p_mensagem text)
returns text language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare s solicitacao;
begin
  select * into s from solicitacao where id = p_id for update;
  if not found or s.estado <> 'enviando' then raise exception 'solicitação % não está em envio', p_id using errcode = 'P0001'; end if;
  if coalesce(array_length(p_numeros, 1), 0) = 0 or array_length(p_numeros, 1) <> array_length(p_sequencias, 1)
     or (select count(distinct x) from unnest(p_numeros) x) <> array_length(p_numeros, 1)
     or exists (select 1 from numero where numero = any (p_numeros)) then
    update solicitacao set estado = 'quarentena', http_status = p_http, resposta = p_resposta, saldo_sncr = p_saldo,
      mensagem = coalesce(p_mensagem, 'números vazios, repetidos ou já registrados'), concluida_em = now() where id = p_id;
    return 'quarentena';
  end if;
  insert into numero (numero, prescritor_id, tipo, solicitacao_id, sequencia)
  select n, s.prescritor_id, s.tipo, s.id, q from unnest(p_numeros, p_sequencias) as t(n, q);
  update solicitacao set estado = 'recebida', http_status = p_http, resposta = p_resposta, saldo_sncr = p_saldo,
    mensagem = p_mensagem, concluida_em = now() where id = p_id;
  return 'recebida';
end $$;

-- 3b. Resposta que não pôde ser validada: guarda o corpo, nada entra no estoque.
create function cockpit_rx.registrar_quarentena(p_id uuid, p_http int, p_resposta jsonb, p_motivo text) returns void
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update solicitacao set estado = 'quarentena', http_status = p_http, resposta = p_resposta, mensagem = p_motivo, concluida_em = now()
   where id = p_id and estado = 'enviando';
  if not found then raise exception 'solicitação % não está em envio', p_id using errcode = 'P0001'; end if;
end $$;

-- 3c. Recusa do SNCR (4xx) ou resultado incerto (timeout, 5xx, rede após o envio).
create function cockpit_rx.encerrar_envio(p_id uuid, p_estado text, p_http int, p_resposta jsonb, p_mensagem text) returns void
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  if p_estado not in ('recusada', 'ambigua') then raise exception 'estado final inválido: %', p_estado using errcode = 'P0001'; end if;
  update solicitacao set estado = p_estado, http_status = p_http, resposta = p_resposta, mensagem = p_mensagem, concluida_em = now()
   where id = p_id and estado = 'enviando';
  if not found then raise exception 'solicitação % não está em envio', p_id using errcode = 'P0001'; end if;
end $$;

-- Intenção preparada e nunca enviada (ex.: login gov.br abandonado).
create function cockpit_rx.descartar_solicitacao(p_id uuid) returns boolean
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update solicitacao set estado = 'descartada', concluida_em = now() where id = p_id and estado = 'preparada';
  return found;
end $$;

-- 4. Reserva idempotente por receita: repetir devolve o mesmo número. Ordem: lote mais antigo, menor sequência.
create function cockpit_rx.reservar_numero(p_prescritor uuid, p_tipo text, p_receita uuid) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare n text;
begin
  select numero into n from numero where receita_id = p_receita and tipo = p_tipo and estado in ('reservado', 'usado');
  if found then return n; end if;
  begin
    with alvo as (
      select numero from numero
       where prescritor_id = p_prescritor and tipo = p_tipo and estado = 'disponivel'
       order by recebido_em, sequencia
       for update skip locked limit 1)
    update numero x set estado = 'reservado', receita_id = p_receita, reservado_em = now()
      from alvo where x.numero = alvo.numero and x.estado = 'disponivel'
    returning x.numero into n;
  exception when unique_violation then
    -- Outra chamada reservou para a mesma receita ao mesmo tempo: devolve aquela.
    select numero into n from numero where receita_id = p_receita and tipo = p_tipo and estado in ('reservado', 'usado');
  end;
  return n; -- null: sem estoque
end $$;

-- O PDF com o número saiu do servidor (enviado para assinatura, baixado): o número não volta mais ao estoque.
create function cockpit_rx.liberar_numero(p_receita uuid, p_tipo text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare n text;
begin
  update numero set liberado = true where receita_id = p_receita and tipo = p_tipo and estado = 'reservado' returning numero into n;
  if n is null then raise exception 'receita sem número reservado de %', p_tipo using errcode = 'P0001'; end if;
  return n;
end $$;

-- Desistência antes de o PDF sair: o número volta ao estoque.
create function cockpit_rx.devolver_numero(p_receita uuid, p_tipo text) returns boolean
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update numero set estado = 'disponivel', receita_id = null, reservado_em = null
   where receita_id = p_receita and tipo = p_tipo and estado = 'reservado' and not liberado;
  return found;
end $$;

-- Assinatura concluída: o número fica ligado ao PDF assinado, em definitivo.
create function cockpit_rx.confirmar_uso(p_receita uuid, p_tipo text, p_pdf_sha256 text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare n text;
begin
  update numero set estado = 'usado', liberado = true, usado_em = now(), pdf_sha256 = p_pdf_sha256
   where receita_id = p_receita and tipo = p_tipo and estado = 'reservado' returning numero into n;
  if n is null then raise exception 'receita sem número reservado de %', p_tipo using errcode = 'P0001'; end if;
  return n;
end $$;

create function cockpit_rx.inutilizar_numero(p_numero text, p_motivo text) returns void
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update numero set estado = 'inutilizado', inutilizado_em = now(), motivo = p_motivo
   where numero = p_numero and estado in ('disponivel', 'reservado');
  if not found then raise exception 'número % não pode ser inutilizado', p_numero using errcode = 'P0001'; end if;
end $$;

-- Painel "Meus números".
create function cockpit_rx.estoque(p_prescritor uuid)
returns table (tipo text, disponiveis int, reservados int, usados int, inutilizados int)
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select tipo,
         (count(*) filter (where estado = 'disponivel'))::int,
         (count(*) filter (where estado = 'reservado'))::int,
         (count(*) filter (where estado = 'usado'))::int,
         (count(*) filter (where estado = 'inutilizado'))::int
    from numero where prescritor_id = p_prescritor group by tipo order by tipo
$$;

-- Papel da aplicação: executa as funções; não lê nem altera tabelas diretamente.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'cockpit_rx_app') then create role cockpit_rx_app nologin; end if;
end $$;
revoke all on all tables in schema cockpit_rx from public;
revoke all on all functions in schema cockpit_rx from public;
grant usage on schema cockpit_rx to cockpit_rx_app;
grant execute on function
  cockpit_rx.preparar_solicitacao(uuid, text, int, text, text), cockpit_rx.iniciar_envio(uuid),
  cockpit_rx.registrar_recebimento(uuid, int, jsonb, text[], bigint[], int, text), cockpit_rx.registrar_quarentena(uuid, int, jsonb, text),
  cockpit_rx.encerrar_envio(uuid, text, int, jsonb, text), cockpit_rx.descartar_solicitacao(uuid),
  cockpit_rx.reservar_numero(uuid, text, uuid), cockpit_rx.liberar_numero(uuid, text), cockpit_rx.devolver_numero(uuid, text),
  cockpit_rx.confirmar_uso(uuid, text, text), cockpit_rx.inutilizar_numero(text, text), cockpit_rx.estoque(uuid)
  to cockpit_rx_app;

-- Defesa extra no Supabase: RLS ligado sem políticas (o schema também não é exposto pela API).
alter table cockpit_rx.prescritor enable row level security;
alter table cockpit_rx.solicitacao enable row level security;
alter table cockpit_rx.numero enable row level security;
alter table cockpit_rx.evento enable row level security;
