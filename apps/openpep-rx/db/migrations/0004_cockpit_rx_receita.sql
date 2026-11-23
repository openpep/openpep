-- Etapa 3: receita com número do registro, PDF assinado e histórico (docs/SNCR-NUMEROS-FLUXO.md, seção 5).
-- Homologação: dados fictícios e marca "sem validade para dispensação" no PDF.
--
-- Estados:  rascunho -> emitindo -> emitida
--                        emitindo -> rascunho  (falha antes de o PDF sair do servidor: o número volta ao estoque)
--                        emitindo -> pendente  (falha depois: o número fica na receita para nova tentativa)
--           pendente -> emitindo (nova tentativa, mesmo número) | cancelada (número inutilizado)
--           rascunho -> cancelada

create table cockpit_rx.receita (
  id uuid primary key, -- gerado pela tela: repetir o envio não cria outra receita
  prescritor_id uuid not null references cockpit_rx.prescritor (id),
  tipo text not null check (tipo in ('NRA', 'NRB', 'NRB2', 'NRR', 'NRT', 'RCE', 'RET')),
  estado text not null default 'rascunho' check (estado in ('rascunho', 'emitindo', 'pendente', 'emitida', 'cancelada')),
  conteudo jsonb not null,
  conteudo_sha256 text not null check (conteudo_sha256 ~ '^[a-f0-9]{64}$'),
  numero text unique references cockpit_rx.numero (numero),
  criada_em timestamptz not null default now(),
  atualizada_em timestamptz not null default now(),
  emissao_iniciada_em timestamptz,
  emitida_em timestamptz,
  cancelada_em timestamptz,
  motivo text,
  pdf_assinado bytea,
  pdf_sha256 text check (pdf_sha256 ~ '^[a-f0-9]{64}$'),
  certificado_serial text,
  check (estado not in ('emitindo', 'pendente', 'emitida') or numero is not null),
  check (estado <> 'emitida' or (pdf_assinado is not null and pdf_sha256 is not null and emitida_em is not null)),
  check (estado <> 'cancelada' or char_length(motivo) between 3 and 300)
);
create index receita_historico on cockpit_rx.receita (prescritor_id, criada_em desc);

-- Transições válidas; conteúdo fixado quando a emissão começa; estados finais imutáveis.
create function cockpit_rx.validar_receita() returns trigger language plpgsql set search_path = cockpit_rx, pg_temp as $$
begin
  if (new.id, new.prescritor_id, new.criada_em) is distinct from (old.id, old.prescritor_id, old.criada_em) then
    raise exception 'receita %: identidade imutável', old.id using errcode = 'P0001';
  end if;
  if old.estado in ('emitida', 'cancelada') then
    raise exception 'receita %: estado final', old.id using errcode = 'P0001';
  end if;
  if old.estado <> 'rascunho' and (new.tipo, new.conteudo, new.conteudo_sha256) is distinct from (old.tipo, old.conteudo, old.conteudo_sha256) then
    raise exception 'receita %: conteúdo fixado na emissão', old.id using errcode = 'P0001';
  end if;
  if old.estado <> new.estado and not (
       (old.estado = 'rascunho' and new.estado in ('emitindo', 'cancelada'))
    or (old.estado = 'emitindo' and new.estado in ('emitida', 'pendente', 'rascunho'))
    or (old.estado = 'pendente' and new.estado in ('emitindo', 'cancelada'))
  ) then
    raise exception 'receita %: transição % -> % não permitida', old.id, old.estado, new.estado using errcode = 'P0001';
  end if;
  -- O número só sai da receita quando volta ao estoque (emitindo -> rascunho).
  if old.numero is not null and new.numero is distinct from old.numero
     and not (old.estado = 'emitindo' and new.estado = 'rascunho' and new.numero is null) then
    raise exception 'receita %: número não pode mudar', old.id using errcode = 'P0001';
  end if;
  return new;
end $$;

-- Auditoria sem o PDF (o hash fica na linha e no número).
create function cockpit_rx.auditar_receita() returns trigger language plpgsql set search_path = cockpit_rx, pg_temp as $$
begin
  insert into evento (entidade, chave, acao, antes, depois)
  values ('receita', new.id::text, lower(tg_op),
          case when tg_op = 'UPDATE' then to_jsonb(old) - 'pdf_assinado' end, to_jsonb(new) - 'pdf_assinado');
  return new;
end $$;

create trigger receita_valida before update on cockpit_rx.receita for each row execute function cockpit_rx.validar_receita();
create trigger receita_sem_exclusao before delete on cockpit_rx.receita for each row execute function cockpit_rx.somente_inclusao();
create trigger receita_audita after insert or update on cockpit_rx.receita for each row execute function cockpit_rx.auditar_receita();

-- Rascunho: criado ou atualizado enquanto a emissão não começou.
create function cockpit_rx.salvar_rascunho(p_id uuid, p_prescritor uuid, p_tipo text, p_conteudo jsonb, p_sha text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare r receita;
begin
  select * into r from receita where id = p_id for update;
  if not found then
    insert into receita (id, prescritor_id, tipo, conteudo, conteudo_sha256) values (p_id, p_prescritor, p_tipo, p_conteudo, p_sha);
    return 'rascunho';
  end if;
  if r.prescritor_id <> p_prescritor then raise exception 'receita não encontrada' using errcode = 'P0001'; end if;
  if r.estado <> 'rascunho' then raise exception 'esta receita já foi enviada para emissão; crie uma nova' using errcode = 'P0001'; end if;
  update receita set tipo = p_tipo, conteudo = p_conteudo, conteudo_sha256 = p_sha, atualizada_em = now() where id = p_id;
  return 'rascunho';
end $$;

-- Início da emissão: reserva o número (ou devolve o que a receita já tem). O conteúdo precisa ser o da prévia.
-- Uma emissão interrompida no meio (função encerrada) pode ser retomada depois de 3 minutos, com o mesmo número.
create function cockpit_rx.iniciar_emissao(p_id uuid, p_prescritor uuid, p_sha text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare r receita; n text;
begin
  select * into r from receita where id = p_id for update;
  if not found or r.prescritor_id <> p_prescritor then raise exception 'receita não encontrada' using errcode = 'P0001'; end if;
  if r.estado = 'emitida' then raise exception 'receita já emitida' using errcode = 'P0001'; end if;
  if r.estado = 'cancelada' then raise exception 'receita cancelada' using errcode = 'P0001'; end if;
  if r.conteudo_sha256 <> p_sha then raise exception 'a receita mudou depois da prévia; revise de novo' using errcode = 'P0001'; end if;
  if r.estado = 'emitindo' and r.emissao_iniciada_em > now() - interval '3 minutes' then
    raise exception 'emissão em andamento' using errcode = 'P0001';
  end if;
  n := reservar_numero(p_prescritor, r.tipo, p_id);
  if n is null then raise exception 'sem números % disponíveis; solicite em Meus números', r.tipo using errcode = 'P0001'; end if;
  update receita set estado = 'emitindo', numero = n, emissao_iniciada_em = now(), atualizada_em = now() where id = p_id;
  return n;
end $$;

-- Falha na emissão. Se o PDF com o número nunca saiu do servidor, o número volta ao estoque;
-- senão a receita fica pendente com o mesmo número.
create function cockpit_rx.falhar_emissao(p_id uuid, p_prescritor uuid) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare r receita;
begin
  select * into r from receita where id = p_id for update;
  if not found or r.prescritor_id <> p_prescritor or r.estado <> 'emitindo' then
    raise exception 'receita não está em emissão' using errcode = 'P0001';
  end if;
  if devolver_numero(p_id, r.tipo) then
    update receita set estado = 'rascunho', numero = null, emissao_iniciada_em = null, atualizada_em = now() where id = p_id;
    return 'rascunho';
  end if;
  update receita set estado = 'pendente', atualizada_em = now() where id = p_id;
  return 'pendente';
end $$;

-- Assinatura conferida: número usado e PDF assinado gravados na mesma transação.
create function cockpit_rx.concluir_emissao(p_id uuid, p_prescritor uuid, p_pdf_base64 text, p_pdf_sha256 text, p_serial text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare r receita; n text; pdf bytea := decode(p_pdf_base64, 'base64');
begin
  select * into r from receita where id = p_id for update;
  if not found or r.prescritor_id <> p_prescritor or r.estado <> 'emitindo' then
    raise exception 'receita não está em emissão' using errcode = 'P0001';
  end if;
  if encode(sha256(pdf), 'hex') <> p_pdf_sha256 then raise exception 'hash do PDF assinado não confere' using errcode = 'P0001'; end if;
  n := confirmar_uso(p_id, r.tipo, p_pdf_sha256);
  update receita set estado = 'emitida', pdf_assinado = pdf, pdf_sha256 = p_pdf_sha256, certificado_serial = p_serial,
    emitida_em = now(), atualizada_em = now() where id = p_id;
  return n;
end $$;

-- Cancelamento: rascunho simplesmente encerra; pendente inutiliza o número (o PDF já saiu do servidor).
create function cockpit_rx.cancelar_receita(p_id uuid, p_prescritor uuid, p_motivo text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare r receita;
begin
  select * into r from receita where id = p_id for update;
  if not found or r.prescritor_id <> p_prescritor then raise exception 'receita não encontrada' using errcode = 'P0001'; end if;
  if r.estado not in ('rascunho', 'pendente') then raise exception 'só rascunho ou receita pendente podem ser cancelados' using errcode = 'P0001'; end if;
  if r.estado = 'pendente' then perform inutilizar_numero(r.numero, left('receita cancelada: ' || p_motivo, 300)); end if;
  update receita set estado = 'cancelada', motivo = p_motivo, cancelada_em = now(), atualizada_em = now() where id = p_id;
  return 'cancelada';
end $$;

-- Uma receita do prescritor, sem o PDF.
create function cockpit_rx.receita_do_prescritor(p_id uuid, p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object('id', id, 'tipo', tipo, 'estado', estado, 'numero', numero, 'conteudo', conteudo,
           'conteudoSha256', conteudo_sha256, 'criadaEm', criada_em, 'emitidaEm', emitida_em, 'pdfSha256', pdf_sha256)
    from receita where id = p_id and prescritor_id = p_prescritor
$$;

-- PDF assinado, só da receita emitida e do próprio prescritor.
create function cockpit_rx.receita_pdf(p_id uuid, p_prescritor uuid) returns text
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select encode(pdf_assinado, 'base64') from receita where id = p_id and prescritor_id = p_prescritor and estado = 'emitida'
$$;

-- Histórico (sem o PDF) e o último endereço de emitente usado, para preencher a próxima receita.
create function cockpit_rx.receitas(p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object(
    'lista', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'estado', estado, 'numero', numero,
               'paciente', conteudo #>> '{paciente,nome}', 'medicamento', conteudo #>> '{medicamento,nome}',
               'criadaEm', criada_em, 'emitidaEm', emitida_em, 'motivo', motivo, 'hash', conteudo_sha256) order by criada_em desc)
      from (select * from receita where prescritor_id = p_prescritor and not (estado = 'cancelada' and numero is null)
             order by criada_em desc limit 50) r), '[]'::jsonb),
    'emitente', (select conteudo -> 'emitente' from receita where prescritor_id = p_prescritor order by criada_em desc limit 1))
$$;

revoke all on table cockpit_rx.receita from public;
revoke all on function
  cockpit_rx.salvar_rascunho(uuid, uuid, text, jsonb, text), cockpit_rx.iniciar_emissao(uuid, uuid, text),
  cockpit_rx.falhar_emissao(uuid, uuid), cockpit_rx.concluir_emissao(uuid, uuid, text, text, text),
  cockpit_rx.cancelar_receita(uuid, uuid, text), cockpit_rx.receita_do_prescritor(uuid, uuid),
  cockpit_rx.receita_pdf(uuid, uuid), cockpit_rx.receitas(uuid),
  cockpit_rx.validar_receita(), cockpit_rx.auditar_receita()
  from public;
grant execute on function
  cockpit_rx.salvar_rascunho(uuid, uuid, text, jsonb, text), cockpit_rx.iniciar_emissao(uuid, uuid, text),
  cockpit_rx.falhar_emissao(uuid, uuid), cockpit_rx.concluir_emissao(uuid, uuid, text, text, text),
  cockpit_rx.cancelar_receita(uuid, uuid, text), cockpit_rx.receita_do_prescritor(uuid, uuid),
  cockpit_rx.receita_pdf(uuid, uuid), cockpit_rx.receitas(uuid)
  to cockpit_rx_app;
alter table cockpit_rx.receita enable row level security;
