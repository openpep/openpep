-- O código do paciente passa a ser impresso no PDF, abaixo do QR de acesso (decisão do usuário, 29/09/2026).
-- Por isso ele é gravado na emissão, na mesma transação do PDF assinado, e não muda mais: trocar o código faria
-- o QR impresso parar de funcionar. O PDF gravado já contém o código, então guardá-lo não expõe nada novo.

alter table cockpit_rx.receita add column acesso_codigo text check (acesso_codigo ~ '^[0-9]{6}$');

-- Mesmas regras da 0005; numa receita emitida, só os campos de acesso podem mudar.
create or replace function cockpit_rx.validar_receita() returns trigger language plpgsql set search_path = cockpit_rx, pg_temp as $$
begin
  if (new.id, new.prescritor_id, new.criada_em) is distinct from (old.id, old.prescritor_id, old.criada_em) then
    raise exception 'receita %: identidade imutável', old.id using errcode = 'P0001';
  end if;
  if old.estado = 'cancelada'
     or (old.estado = 'emitida' and (to_jsonb(new) - 'acesso_hash' - 'acesso_gerado_em' - 'acesso_codigo')
         is distinct from (to_jsonb(old) - 'acesso_hash' - 'acesso_gerado_em' - 'acesso_codigo')) then
    raise exception 'receita %: estado final', old.id using errcode = 'P0001';
  end if;
  -- O código impresso no PDF não muda.
  if old.acesso_codigo is not null and new.acesso_codigo is distinct from old.acesso_codigo then
    raise exception 'receita %: código de acesso impresso no PDF', old.id using errcode = 'P0001';
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
  if old.numero is not null and new.numero is distinct from old.numero
     and not (old.estado = 'emitindo' and new.estado = 'rascunho' and new.numero is null) then
    raise exception 'receita %: número não pode mudar', old.id using errcode = 'P0001';
  end if;
  return new;
end $$;

-- Emissão concluída com o código impresso no PDF: número usado, PDF assinado e acesso na mesma transação.
create function cockpit_rx.concluir_emissao_com_acesso(p_id uuid, p_prescritor uuid, p_pdf_base64 text, p_pdf_sha256 text, p_serial text,
  p_codigo text, p_hash text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare n text;
begin
  n := concluir_emissao(p_id, p_prescritor, p_pdf_base64, p_pdf_sha256, p_serial);
  update receita set acesso_codigo = p_codigo, acesso_hash = p_hash, acesso_gerado_em = now() where id = p_id;
  return n;
end $$;

-- Código da receita emitida: o que foi impresso; receitas emitidas antes desta migration recebem um agora.
create function cockpit_rx.codigo_acesso(p_id uuid, p_prescritor uuid, p_codigo text, p_hash text) returns text
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
declare r receita;
begin
  select * into r from receita where id = p_id and prescritor_id = p_prescritor for update;
  if not found or r.estado <> 'emitida' then raise exception 'receita emitida não encontrada' using errcode = 'P0001'; end if;
  if r.acesso_codigo is not null then return r.acesso_codigo; end if;
  update receita set acesso_codigo = p_codigo, acesso_hash = p_hash, acesso_gerado_em = now() where id = p_id;
  return p_codigo;
end $$;

-- Histórico com o código de acesso das receitas emitidas (para o link do WhatsApp).
create or replace function cockpit_rx.receitas(p_prescritor uuid) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object(
    'lista', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'estado', estado, 'numero', numero,
               'paciente', conteudo #>> '{paciente,nome}', 'medicamento', conteudo #>> '{medicamento,nome}',
               'criadaEm', criada_em, 'emitidaEm', emitida_em, 'motivo', motivo, 'hash', conteudo_sha256,
               'codigo', case when estado = 'emitida' then acesso_codigo end) order by criada_em desc)
      from (select * from receita where prescritor_id = p_prescritor and not (estado = 'cancelada' and numero is null)
             order by criada_em desc limit 50) r), '[]'::jsonb),
    'emitente', (select conteudo -> 'emitente' from receita where prescritor_id = p_prescritor order by criada_em desc limit 1))
$$;

revoke all on function cockpit_rx.concluir_emissao_com_acesso(uuid, uuid, text, text, text, text, text), cockpit_rx.codigo_acesso(uuid, uuid, text, text) from public;
grant execute on function cockpit_rx.concluir_emissao_com_acesso(uuid, uuid, text, text, text, text, text), cockpit_rx.codigo_acesso(uuid, uuid, text, text) to cockpit_rx_app;
