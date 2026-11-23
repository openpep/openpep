-- Acesso à receita emitida pelo QR da plataforma com código do paciente (docs/SNCR-NUMEROS-FLUXO.md, seção 13).
-- Só o hash do código fica gravado: sha256("<id da receita>:<código>"). Um novo código substitui o anterior.

alter table cockpit_rx.receita
  add column acesso_hash text check (acesso_hash ~ '^[a-f0-9]{64}$'),
  add column acesso_gerado_em timestamptz,
  add check (acesso_hash is null or estado = 'emitida');

-- Mesmas regras da 0004; numa receita emitida, só o código de acesso pode mudar.
create or replace function cockpit_rx.validar_receita() returns trigger language plpgsql set search_path = cockpit_rx, pg_temp as $$
begin
  if (new.id, new.prescritor_id, new.criada_em) is distinct from (old.id, old.prescritor_id, old.criada_em) then
    raise exception 'receita %: identidade imutável', old.id using errcode = 'P0001';
  end if;
  if old.estado = 'cancelada'
     or (old.estado = 'emitida' and (to_jsonb(new) - 'acesso_hash' - 'acesso_gerado_em') is distinct from (to_jsonb(old) - 'acesso_hash' - 'acesso_gerado_em')) then
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
  if old.numero is not null and new.numero is distinct from old.numero
     and not (old.estado = 'emitindo' and new.estado = 'rascunho' and new.numero is null) then
    raise exception 'receita %: número não pode mudar', old.id using errcode = 'P0001';
  end if;
  return new;
end $$;

-- Novo código de acesso (o anterior deixa de valer). Só o prescritor da receita, só receita emitida.
create function cockpit_rx.definir_acesso(p_id uuid, p_prescritor uuid, p_hash text) returns void
language plpgsql security definer set search_path = cockpit_rx, pg_temp as $$
begin
  update receita set acesso_hash = p_hash, acesso_gerado_em = now()
   where id = p_id and prescritor_id = p_prescritor and estado = 'emitida';
  if not found then raise exception 'receita emitida não encontrada' using errcode = 'P0001'; end if;
end $$;

-- Receita emitida para quem tem o identificador (QR) e o código do paciente. Sem CPF do prescritor.
create function cockpit_rx.receita_por_acesso(p_id uuid, p_hash text) returns jsonb
language sql stable security definer set search_path = cockpit_rx, pg_temp as $$
  select jsonb_build_object('tipo', r.tipo, 'numero', r.numero, 'emitidaEm', r.emitida_em, 'pdfSha256', r.pdf_sha256,
           'prescritor', jsonb_build_object('nome', p.nome, 'conselho', p.conselho, 'inscricao', p.inscricao, 'uf', p.uf),
           'pdf', encode(r.pdf_assinado, 'base64'))
    from receita r join prescritor p on p.id = r.prescritor_id
   where r.id = p_id and r.estado = 'emitida' and r.acesso_hash is not null and r.acesso_hash = p_hash
$$;

revoke all on function cockpit_rx.definir_acesso(uuid, uuid, text), cockpit_rx.receita_por_acesso(uuid, text) from public;
grant execute on function cockpit_rx.definir_acesso(uuid, uuid, text), cockpit_rx.receita_por_acesso(uuid, text) to cockpit_rx_app;
