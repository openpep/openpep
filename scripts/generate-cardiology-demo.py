#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
# SPDX-License-Identifier: Apache-2.0

"""Generate the deterministic, fully synthetic cardiology demo vault."""

from __future__ import annotations

import argparse
import hashlib
import json
import textwrap
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas


DISCLAIMER = (
    "DADOS FICTICIOS DE DEMONSTRACAO. NAO USAR PARA CUIDADO, DECISAO "
    "OU ORIENTACAO MEDICA."
)
VAULT_ID = "vlt_01990000-0000-7000-8000-000000000001"
DEVICE_ID = "dev_01990000-0000-7000-8000-000000000002"
DIRECTORY_MARKER_NAME = ".openpep-demo-directory"
DIRECTORY_MARKER_TEXT = "OPENPEP_SYNTHETIC_DEMO_DIRECTORY_V1\n"


@dataclass(frozen=True)
class Case:
    name: str
    birth_date: str
    sex: str
    primary_problem: str
    summary: str
    problems: tuple[str, ...]
    consultations: tuple[str, ...]
    laboratory: str
    imaging: str
    next_appointment: str | None


CASES = (
    Case("Alaide Cobalto", "1958-02-11", "female", "Fibrilacao atrial paroxistica", "Hipertensao e episodios recentes de palpitacao, sem instabilidade descrita no cenario ficticio.", ("Hipertensao arterial", "Fibrilacao atrial paroxistica", "Acompanhamento de anticoagulacao"), ("2024-05-16", "2024-10-03", "2025-04-22", "2026-02-10"), "Hemograma, funcao renal e TSH", "Ecocardiograma transtoracico", "2026-09-04T09:00:00-03:00"),
    Case("Breno Lumen", "1972-07-19", "male", "Doenca coronariana cronica", "Seguimento depois de intervencao coronariana ficticia, com atividade fisica irregular.", ("Doenca arterial coronariana", "Dislipidemia", "Sedentarismo"), ("2024-02-08", "2024-08-15", "2025-03-13"), "Perfil lipidico e painel metabolico", "Teste ergometrico", None),
    Case("Celina Vertice", "1950-11-03", "female", "Insuficiencia cardiaca com fracao reduzida", "Dispneia aos esforcos e fragilidade leve em titulacao cautelosa no roteiro sintetico.", ("Insuficiencia cardiaca", "Disfuncao ventricular esquerda", "Fragilidade leve"), ("2024-09-05", "2024-11-21", "2025-02-27", "2025-07-17", "2026-01-29"), "Creatinina, potassio e peptideo natriuretico", "Radiografia de torax - laudo", "2026-09-03T14:30:00-03:00"),
    Case("Dario Nimbo", "1983-04-27", "male", "Hipertensao de dificil controle", "Investigacao ficticia de medidas elevadas, sono nao reparador e fatores metabolicos.", ("Hipertensao arterial", "Obesidade", "Suspeita de apneia do sono"), ("2025-01-14", "2025-05-09", "2025-12-04"), "Painel para hipertensao secundaria", "Monitorizacao ambulatorial da pressao", "2026-09-09T16:00:00-03:00"),
    Case("Esmeralda Riacho", "1967-09-14", "female", "Estenose aortica moderada", "Vigilancia ecocardiografica ficticia, sem limitacao funcional referida.", ("Estenose aortica moderada", "Hipertensao controlada"), ("2024-04-11", "2025-04-24", "2026-04-30"), "Hemograma e painel metabolico", "Ecocardiograma transtoracico", None),
    Case("Fabio Ambar", "1991-01-22", "male", "Palpitacoes com extrassistoles isoladas", "Sintomas relacionados a cafeina e estresse, sem cardiopatia estrutural no cenario.", ("Extrassistoles isoladas", "Ansiedade situacional"), ("2025-03-06", "2025-07-24"), "Funcao tireoidiana e eletrolitos", "Holter de 48 horas", None),
    Case("Gilda Horizonte", "1954-06-08", "female", "Fibrilacao atrial persistente", "Controle de frequencia e conciliacao ficticia em contexto de funcao renal reduzida.", ("Fibrilacao atrial persistente", "Doenca renal cronica estagio 3", "Risco de quedas"), ("2024-06-20", "2024-12-12", "2025-06-26", "2026-03-19"), "Hemograma e funcao renal", "Eletrocardiograma de repouso", "2026-09-11T10:30:00-03:00"),
    Case("Heitor Prisma", "1965-12-30", "male", "Prevencao secundaria coronariana", "Retorno gradual as atividades depois de sindrome coronariana ficticia em 2024.", ("Doenca arterial coronariana", "Tabagismo em cessacao", "Dislipidemia"), ("2024-07-02", "2024-09-17", "2025-01-30", "2025-08-21"), "Perfil lipidico e glicemia", "Teste ergometrico", None),
    Case("Iara Solsticio", "1979-03-05", "female", "Taquicardia supraventricular recorrente", "Episodios abruptos e decisao compartilhada ficticia sobre avaliacao eletrofisiologica.", ("Taquicardia supraventricular", "Palpitacoes"), ("2025-02-13", "2025-06-05", "2026-02-12"), "Hemograma, eletrólitos e TSH", "Holter prolongado", "2026-09-02T11:00:00-03:00"),
    Case("Jairo Quasar", "1944-08-17", "male", "Acompanhamento de marcapasso", "Seguimento ficticio de dispositivo e insuficiencia mitral moderada.", ("Marcapasso definitivo", "Insuficiencia mitral moderada", "Tontura episodica"), ("2024-03-28", "2024-10-10", "2025-04-03", "2025-10-02", "2026-04-09"), "Funcao renal e eletrólitos", "Interrogacao de marcapasso - laudo", None),
    Case("Katia Boreal", "1976-05-26", "female", "Miocardiopatia hipertrofica nao obstrutiva", "Avaliacao ficticia de sintomas aos esforcos e historia familiar igualmente sintetica.", ("Miocardiopatia hipertrofica", "Risco familiar em avaliacao"), ("2024-08-08", "2025-02-20", "2025-09-11", "2026-05-14"), "Hemograma e painel metabolico", "Ressonancia magnetica cardiaca - laudo", "2026-09-15T15:30:00-03:00"),
    Case("Lucio Mosaico", "1962-10-09", "male", "Risco cardiovascular elevado", "Diabetes, hipertensao e claudicacao estavel no caso demonstrativo.", ("Diabetes tipo 2", "Hipertensao arterial", "Doenca arterial periferica"), ("2024-01-18", "2024-07-11", "2025-01-23", "2025-07-31"), "Hemoglobina glicada e perfil lipidico", "Doppler arterial de membros inferiores", None),
    Case("Miriam Zenite", "1956-01-31", "female", "Hipertensao pulmonar em investigacao", "Dispneia multifatorial em acompanhamento conjunto ficticio com pneumologia.", ("Suspeita de hipertensao pulmonar", "Dispneia cronica"), ("2024-11-07", "2025-03-20", "2025-09-25", "2026-03-05"), "Painel autoimune basico e funcao renal", "Angiotomografia de torax - laudo", "2026-09-17T08:30:00-03:00"),
    Case("Nestor Circulo", "1968-02-24", "male", "Aneurisma estavel de aorta ascendente", "Comparacao seriada ficticia de medidas e controle pressor.", ("Aneurisma de aorta ascendente", "Hipertensao arterial"), ("2024-05-23", "2024-11-14", "2025-05-22", "2026-05-28"), "Funcao renal antes de contraste", "Angiotomografia de aorta - laudo", None),
    Case("Ofelia Marfim", "1939-07-07", "female", "Insuficiencia cardiaca com fracao preservada", "Edema, hipotensao postural e revisao ficticia de polifarmacia com familiar.", ("Insuficiencia cardiaca", "Fibrilacao atrial", "Hipotensao postural"), ("2024-02-22", "2024-08-29", "2025-02-06", "2025-08-14", "2026-02-19"), "Hemograma, funcao renal e eletrólitos", "Monitorizacao ambulatorial da pressao", "2026-09-18T09:30:00-03:00"),
    Case("Persio Estelar", "1997-11-12", "male", "Dor toracica atipica", "Investigacao ficticia apos virose sem evidencia de miocardite ativa.", ("Dor toracica atipica", "Ansiedade relacionada a sintomas"), ("2025-04-03", "2025-04-24", "2025-08-07"), "Troponina e marcadores inflamatorios", "Ressonancia magnetica cardiaca - laudo", None),
    Case("Quiteria Oliva", "1960-03-18", "female", "Angina com coronarias nao obstrutivas", "Sintomas aos esforcos e impacto funcional em seguimento demonstrativo.", ("Suspeita de doenca microvascular", "Dislipidemia"), ("2024-10-01", "2025-01-09", "2025-06-12", "2026-01-15"), "Perfil lipidico e funcao renal", "Ecocardiograma sob estresse", "2026-09-21T13:30:00-03:00"),
    Case("Raul Meridian", "1952-09-02", "male", "Acompanhamento depois de TAVI ficticio", "Seguimento demonstrativo de protese valvar e anemia em investigacao.", ("Protese aortica transcateter", "Anemia em investigacao"), ("2025-02-06", "2025-04-17", "2025-10-23", "2026-04-16"), "Hemograma, ferro e ferritina", "Ecocardiograma de protese aortica", None),
    Case("Silvia Ametista", "1985-06-21", "female", "Risco cardiovascular depois de hipertensao gestacional", "Prevencao longitudinal e planejamento reprodutivo no roteiro ficticio.", ("Antecedente de hipertensao gestacional", "Risco metabolico"), ("2024-03-14", "2024-09-19", "2025-09-18"), "Painel metabolico e perfil lipidico", "Ecocardiograma transtoracico", "2026-09-23T17:00:00-03:00"),
    Case("Tadeu Safira", "1970-12-04", "male", "Dislipidemia familiar provavel", "Escore de calcio elevado e doenca coronariana subclinica no cenario sintetico.", ("Dislipidemia importante", "Doenca coronariana subclinica"), ("2024-06-13", "2024-12-05", "2025-06-19", "2026-06-11"), "Perfil lipidico, ApoB e Lp(a)", "Angiotomografia coronariana - laudo", "2026-09-25T11:30:00-03:00"),
)


def opaque_id(prefix: str, patient_index: int, item_index: int = 1) -> str:
    category = {"pt": 0, "enc": 1, "note": 2, "usr": 3, "asset": 4}[prefix]
    first = 0x01990000 + category * 0x1000 + patient_index
    tail = category * 1_000_000 + patient_index * 100 + item_index
    return f"{prefix}_{first:08x}-0000-7000-8000-{tail:012d}"


def iso_utc(day: str, hour: int = 13) -> str:
    parsed = date.fromisoformat(day)
    return datetime(parsed.year, parsed.month, parsed.day, hour, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def age_on(birth_date: str, reference: date = date(2026, 8, 30)) -> int:
    born = date.fromisoformat(birth_date)
    return reference.year - born.year - ((reference.month, reference.day) < (born.month, born.day))


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(text)


def draw_wrapped(pdf: canvas.Canvas, lines: list[str], title: str) -> None:
    width, height = A4
    margin = 54
    y = height - 58
    page = 1

    def header() -> float:
        pdf.setFont("Helvetica-Bold", 15)
        pdf.drawString(margin, height - 48, title)
        pdf.setFont("Helvetica-Bold", 8)
        pdf.drawString(margin, height - 66, DISCLAIMER)
        pdf.setStrokeColorRGB(0.65, 0.65, 0.65)
        pdf.line(margin, height - 74, width - margin, height - 74)
        return height - 94

    y = header()
    for raw in lines:
        wrapped = textwrap.wrap(raw, width=92, break_long_words=False) or [""]
        for line in wrapped:
            if y < 62:
                pdf.setFont("Helvetica", 8)
                pdf.drawRightString(width - margin, 36, f"Pagina {page}")
                pdf.showPage()
                page += 1
                y = header()
            pdf.setFont("Helvetica", 10)
            pdf.drawString(margin, y, line)
            y -= 14
        y -= 4
    pdf.setFont("Helvetica", 8)
    pdf.drawRightString(width - margin, 36, f"Pagina {page}")


def create_pdf(path: Path, title: str, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pdf = canvas.Canvas(str(path), pagesize=A4, pageCompression=1, invariant=1)
    pdf.setTitle(title)
    pdf.setAuthor("OpenPEP synthetic fixture generator")
    draw_wrapped(pdf, lines, title)
    pdf.save()


def laboratory_values(patient_index: int) -> list[str]:
    """Return deterministic variations so the demo does not repeat one panel."""
    decimal = lambda value, digits: f"{value:.{digits}f}".replace(".", ",")
    hemoglobin = 11.6 + ((patient_index * 7) % 25) / 10
    creatinine = 0.68 + ((patient_index * 11) % 18) / 20
    potassium = 3.7 + ((patient_index * 3) % 10) / 10
    ldl = 58 + ((patient_index * 17) % 91)
    glycated = 5.2 + ((patient_index * 5) % 23) / 10
    return [
        f"Hemoglobina: {decimal(hemoglobin, 1)} g/dL (valor ficticio)",
        f"Creatinina: {decimal(creatinine, 2)} mg/dL (valor ficticio)",
        f"Potassio: {decimal(potassium, 1)} mmol/L (valor ficticio)",
        f"Colesterol LDL: {ldl} mg/dL (valor ficticio)",
        f"Hemoglobina glicada: {decimal(glycated, 1)}% (valor ficticio)",
    ]


def transcript(case: Case, consultation_date: str) -> str:
    topics = (
        "inicio e evolucao dos sintomas",
        "rotina de atividade fisica e sono",
        "uso cotidiano das medicacoes descritas no cenario",
        "percepcao de efeitos indesejados e barreiras de adesao",
        "alimentacao, trabalho, apoio familiar e objetivos pessoais",
        "sinais de alerta explicados apenas como parte da simulacao",
        "duvidas do paciente ficticio e confirmacao de entendimento",
    )
    paragraphs = [DISCLAIMER, "", f"Transcricao sintetica - {case.name} - {consultation_date}", ""]
    for cycle in range(1, 9):
        topic = topics[(cycle - 1) % len(topics)]
        paragraphs.extend((
            f"Medico ficticio: Nesta parte {cycle}, vamos revisar {topic}. Conte com suas palavras como isso apareceu desde a consulta anterior.",
            f"Paciente ficticio: Eu percebi mudancas relacionadas a {case.primary_problem.lower()}. O relato foi escrito apenas para testar uma interface longa. Alguns dias foram tranquilos e outros exigiram pausas, mas nao houve um evento real por tras deste texto.",
            f"Medico ficticio: Registro o contexto de {case.summary.lower()} Vamos separar o que foi observado, o que permanece incerto e o que precisa ser revisto em outro encontro de demonstracao.",
            "Paciente ficticio: Entendi que estes valores, sintomas e dialogos foram inventados. Posso repetir o combinado do roteiro e apontar onde ainda tenho duvida, sem transformar este material em orientacao para uma pessoa real.",
            "Observacao de transcricao: houve pausa, reformulacao de uma pergunta e confirmacao verbal de entendimento. Nenhum audio real foi usado para produzir este conteudo.",
            "",
        ))
    return "\n".join(paragraphs).strip() + "\n"


def note_body(case: Case, consultation_date: str, position: int) -> str:
    problem_lines = "\n".join(f"- {problem}" for problem in case.problems)
    return f"""# Consulta cardiologica sintetica {position}

> {DISCLAIMER}

## Contexto

Consulta ficticia de {consultation_date}. {case.summary}

## Problemas acompanhados

{problem_lines}

## Relato sintetico

O paciente de demonstracao descreve variacao dos sintomas e da rotina desde o
encontro anterior. O texto existe para testar leitura longitudinal, busca e
edicao de rascunho. Nenhuma medida, diagnostico ou conduta deve ser aplicada a
uma pessoa real.

## Avaliacao e plano de demonstracao

Registro mantido como rascunho nao autenticado. Os proximos passos citados no
roteiro sao deliberadamente genericos: revisar os documentos ficticios,
reavaliar sintomas no proximo encontro e confirmar qualquer decisao somente em
um fluxo profissional futuro que ainda nao existe no MVP.
"""


def sidecar(patient_id: str, asset_id: str, path: Path, original_name: str, media_type: str, imported_at: str) -> str:
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    return f"""---
schema: openpep/raw-asset@1
asset_id: {asset_id}
patient_id: {patient_id}
encounter_id: null
media_type: {media_type}
file_extension: {path.suffix.removeprefix('.')}
original_name: {original_name}
size_bytes: {len(data)}
sha256: {digest}
source: fixture_generation
actor_id: null
device_id: {DEVICE_ID}
imported_at: "{imported_at}"
quarantine_state: not_required_synthetic_fixture
inspection_result: generated_demo_fixture
x_fixture_profile: cardiology_demo_v1
---
"""


def generate(destination: Path) -> None:
    if destination.exists():
        raise RuntimeError("Refusing to replace an existing directory")
    destination.mkdir(parents=True)
    for relative in (
        "operations/schemas", "operations/snapshots/patients",
        "operations/snapshots/appointments", "operations/snapshots/actions",
        "operations/ledger", "operations/checkpoints", "patients", "indexes",
        "backups",
    ):
        (destination / relative).mkdir(parents=True)
    for relative in (
        "operations/schemas", "operations/snapshots/patients",
        "operations/snapshots/appointments", "operations/snapshots/actions",
        "operations/ledger", "operations/checkpoints", "backups",
    ):
        write_text(destination / relative / DIRECTORY_MARKER_NAME, DIRECTORY_MARKER_TEXT)

    write_text(destination / "README.txt", f"OpenPEP cardiology demo vault\n\n{DISCLAIMER}\n")
    write_text(destination / "vault.yaml", f"""schema: openpep/vault@1
vault_id: {VAULT_ID}
created_at: "2026-08-30T20:00:00Z"
protocol_version: "1.0"
clinical_writer:
  device_id: {DEVICE_ID}
storage_mode: local-portable
encryption_mode: local-filevault
hash_algorithm: sha256
event_canonicalization: rfc8785
x_profile: cardiology_demo_v1
""")
    write_text(destination / "operations/manifest.yaml", f"""schema: openpep/operations-manifest@1
vault_id: {VAULT_ID}
state: empty
""")

    catalog_patients = []
    for patient_index, case in enumerate(CASES, start=1):
        patient_id = opaque_id("pt", patient_index)
        patient_root = destination / "patients" / patient_id
        for relative in (".openpep", "content/encounters", "content/notes/drafts", "raw", "wiki"):
            (patient_root / relative).mkdir(parents=True)
        for relative in (".openpep", "wiki"):
            write_text(patient_root / relative / DIRECTORY_MARKER_NAME, DIRECTORY_MARKER_TEXT)

        consultations = []
        actor_id = opaque_id("usr", patient_index)
        for item_index, consultation_date in enumerate(case.consultations, start=1):
            encounter_id = opaque_id("enc", patient_index, item_index)
            note_id = opaque_id("note", patient_index, item_index)
            timestamp = iso_utc(consultation_date)
            write_text(patient_root / "content/encounters" / f"{encounter_id}.md", f"""---
schema: openpep/encounter@1
encounter_id: {encounter_id}
patient_id: {patient_id}
appointment_id: null
status: in_progress
modality: in_person
started_at: "{timestamp}"
ended_at: null
created_by: {actor_id}
x_actor_assurance: synthetic_unauthenticated
x_fixture_profile: cardiology_demo_v1
---
""")
            write_text(patient_root / "content/notes/drafts" / f"{note_id}.md", f"""---
schema: openpep/clinical-note@1
note_id: {note_id}
patient_id: {patient_id}
encounter_id: {encounter_id}
status: draft
note_type: progress
author_id: {actor_id}
created_at: "{timestamp}"
updated_at: "{timestamp}"
source_ids: []
ai_assistance:
  used: false
  generation_id: null
  reviewed_by: null
finalization: null
x_actor_assurance: synthetic_unauthenticated
x_fixture_profile: cardiology_demo_v1
---

{note_body(case, consultation_date, item_index)}""")
            consultations.append({"date": consultation_date, "encounter_id": encounter_id, "note_id": note_id, "status": "draft"})

        raw_specs = (
            ("laboratory", "application/pdf", f"laboratorio-{case.laboratory.lower().replace(' ', '-')}-sintetico.pdf"),
            ("imaging", "application/pdf", f"laudo-{case.imaging.lower().replace(' ', '-')}-sintetico.pdf"),
            ("transcript", "text/plain", "transcricao-consulta-sintetica.txt"),
        )
        raw_items = []
        imported_day = case.consultations[-1]
        year, month = imported_day.split("-")[:2]
        raw_month = patient_root / "raw" / year / month
        raw_month.mkdir(parents=True)
        for asset_index, (kind, media_type, original_name) in enumerate(raw_specs, start=1):
            asset_id = opaque_id("asset", patient_index, asset_index)
            extension = "pdf" if media_type == "application/pdf" else "txt"
            original = raw_month / f"{asset_id}.{extension}"
            if kind == "laboratory":
                create_pdf(original, "Resultado laboratorial sintetico", [
                    f"Paciente ficticio: {case.name}", f"Data sintetica: {imported_day}",
                    f"Painel: {case.laboratory}", "Amostra de valores inventados:",
                    *laboratory_values(patient_index),
                    "Interpretacao: nenhum resultado deste documento foi obtido de pessoa real.", DISCLAIMER,
                ])
            elif kind == "imaging":
                create_pdf(original, "Laudo de imagem sintetico", [
                    f"Paciente ficticio: {case.name}", f"Data sintetica: {imported_day}",
                    f"Exame: {case.imaging}", "Tecnica: descricao criada apenas para demonstracao de prontuario.",
                    f"Achados ficticios: elementos compativeis com o acompanhamento de {case.primary_problem.lower()}, sem imagens associadas.",
                    "Conclusao ficticia: comparar apenas dentro deste conjunto demonstrativo.",
                    "Este laudo nao foi emitido por profissional, servico ou equipamento real.", DISCLAIMER,
                ])
            else:
                write_text(original, transcript(case, imported_day))
            metadata = sidecar(patient_id, asset_id, original, original_name, media_type, iso_utc(imported_day, 16))
            write_text(raw_month / f"{asset_id}.meta.md", metadata)
            raw_items.append({"asset_id": asset_id, "kind": kind, "original_name": original_name, "imported_at": iso_utc(imported_day, 16)})

        catalog_patients.append({
            "patient_id": patient_id,
            "display_name": case.name,
            "birth_date": case.birth_date,
            "age": age_on(case.birth_date),
            "administrative_sex": case.sex,
            "primary_problem": case.primary_problem,
            "summary": case.summary,
            "active_problems": list(case.problems),
            "next_appointment": None if case.next_appointment is None else {
                "starts_at": case.next_appointment,
                "time_zone": "America/Sao_Paulo",
                "modality": "in_person",
                "synthetic": True,
            },
            "consultations": consultations,
            "raw_assets": raw_items,
        })

    catalog = {
        "schema": "openpep/demo-cardiology-index@1",
        "synthetic": True,
        "disclaimer": DISCLAIMER,
        "generated_at": "2026-08-30T20:00:00Z",
        "vault_id": VAULT_ID,
        "patients": catalog_patients,
    }
    write_text(destination / "indexes/openpep-demo-cardiology.json", json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(args.destination.resolve())


if __name__ == "__main__":
    main()
