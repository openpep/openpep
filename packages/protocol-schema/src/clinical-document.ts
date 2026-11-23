// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { ProtocolValidationError, validationError } from "./errors.js";
import { createProtocolAjv, schemaIssues } from "./schema-validation.js";
import { parseYamlSubset } from "./yaml.js";

export interface EncounterDocument {
  readonly schema: "openpep/encounter@1";
  readonly encounter_id: string;
  readonly patient_id: string;
  readonly appointment_id: string | null;
  readonly status: "in_progress";
  readonly modality: "in_person" | "telemedicine";
  readonly started_at: string;
  readonly ended_at: null;
  readonly created_by: string;
  readonly template_id?: string;
  readonly template_version?: string;
  readonly telemedicine?: {
    readonly consent: "confirmed" | "declined" | "not_recorded";
    readonly declared_location: string | null;
    readonly participants: readonly string[];
    readonly limitations: string | null;
    readonly contingency: string | null;
    readonly [extension: `x_${string}`]: unknown;
  } | null;
  readonly x_actor_assurance: "synthetic_unauthenticated";
  readonly [extension: `x_${string}`]: unknown;
}

interface ClinicalDraftCommon {
  readonly schema: "openpep/clinical-note@1" | "openpep/clinical-note@2" |
    "openpep/clinical-note@3" | "openpep/clinical-note@4";
  readonly note_id: string;
  readonly patient_id: string;
  readonly encounter_id: string;
  readonly status: "draft";
  readonly note_type: "progress";
  readonly author_id: string;
  readonly created_at: string;
  readonly updated_at: string;
  readonly source_ids: readonly string[];
  readonly finalization: null;
  readonly x_actor_assurance: "synthetic_unauthenticated";
  readonly [extension: `x_${string}`]: unknown;
}

export interface ClinicalDraftV1Document extends ClinicalDraftCommon {
  readonly schema: "openpep/clinical-note@1";
  readonly ai_assistance: {
    readonly used: false;
    readonly generation_id: null;
    readonly reviewed_by: null;
    readonly [extension: `x_${string}`]: unknown;
  };
}

export interface ClinicalDraftV2Document extends ClinicalDraftCommon {
  readonly schema: "openpep/clinical-note@2";
  readonly ai_assistance: {
    readonly used: true;
    readonly generation_id: string;
    readonly reviewed_by: string;
    readonly provenance_schema: "openpep/consultation-summary-provenance@1";
    readonly engine: "apple/FoundationModels.SystemLanguageModel";
    readonly prompt_version: "openpep/consultation-summary-pt-BR@1";
    readonly locale: "pt-BR";
    readonly generated_at: string;
    readonly source_sha256: string;
    readonly chunk_count: number;
    readonly [extension: `x_${string}`]: unknown;
  };
}

export interface ClinicalAIGeneration {
  readonly generation_id: string;
  readonly accepted_by: string;
  readonly accepted_at: string | null;
  readonly source_id: string;
  readonly source_sha256: string;
  readonly provenance_schema: "openpep/consultation-summary-provenance@1" |
    "openpep/patient-ai-provenance@1" |
    "openpep/progressive-summary-provenance@1";
  readonly engine: string;
  readonly model: string | null;
  readonly response_id: string | null;
  readonly prompt_version: string | null;
  readonly locale: string | null;
  readonly generated_at: string | null;
  readonly chunk_count: number | null;
  readonly [extension: `x_${string}`]: unknown;
}

export interface ClinicalDraftV3Document extends ClinicalDraftCommon {
  readonly schema: "openpep/clinical-note@3";
  readonly ai_assistance: {
    readonly used: true;
    readonly generations: readonly ClinicalAIGeneration[];
    readonly [extension: `x_${string}`]: unknown;
  };
}

export interface ProgressiveSummaryAIGeneration {
  readonly generation_id: string;
  readonly accepted_by: string;
  readonly accepted_at: string;
  readonly source_id: string;
  readonly source_sha256: string;
  readonly provenance_schema: "openpep/progressive-summary-provenance@1";
  readonly engine: "apple/FoundationModels.SystemLanguageModel" | "openai/responses";
  readonly model: string | null;
  readonly response_id: string | null;
  readonly prompt_version: "openpep/progressive-consultation-summary-pt-BR@1" |
    "openpep/progressive-consultation-summary-pt-BR@2" |
    "openpep/progressive-consultation-summary-pt-BR@3" |
    "openpep/progressive-consultation-summary-pt-BR@4" |
    "openpep/progressive-consultation-summary-pt-BR@5" |
    "openpep/final-consultation-summary-apple-pt-BR@1";
  readonly locale: "pt-BR";
  readonly generated_at: string;
  readonly chunk_count: number;
  readonly [extension: `x_${string}`]: unknown;
}

export interface ClinicalDraftV4Document extends ClinicalDraftCommon {
  readonly schema: "openpep/clinical-note@4";
  readonly ai_assistance: {
    readonly used: true;
    readonly generations: readonly (ClinicalAIGeneration | ProgressiveSummaryAIGeneration)[];
    readonly [extension: `x_${string}`]: unknown;
  };
}

export type ClinicalDraftDocument = ClinicalDraftV1Document |
  ClinicalDraftV2Document | ClinicalDraftV3Document | ClinicalDraftV4Document;

export interface ParsedClinicalDraft {
  readonly metadata: ClinicalDraftDocument;
  readonly body: string;
}

const encounterSchema = JSON.parse(readFileSync(new URL(
  "../../schemas/v1/synthetic-encounter-profile.schema.json",
  import.meta.url,
), "utf8")) as object;
const clinicalDraftSchema = JSON.parse(readFileSync(new URL(
  "../../schemas/v1/synthetic-clinical-draft-profile.schema.json",
  import.meta.url,
), "utf8")) as object;
const clinicalDraftV2Schema = JSON.parse(readFileSync(new URL(
  "../../schemas/v2/clinical-draft.schema.json",
  import.meta.url,
), "utf8")) as object;
const clinicalDraftV3Schema = JSON.parse(readFileSync(new URL(
  "../../schemas/v3/clinical-draft.schema.json",
  import.meta.url,
), "utf8")) as object;
const clinicalDraftV4Schema = JSON.parse(readFileSync(new URL(
  "../../schemas/v4/clinical-draft.schema.json",
  import.meta.url,
), "utf8")) as object;

const ajv = createProtocolAjv();
const validateEncounterSchema = ajv.compile<EncounterDocument>(encounterSchema);
const validateClinicalDraftSchema = ajv.compile<ClinicalDraftDocument>(
  clinicalDraftSchema,
);
const validateClinicalDraftV2Schema = ajv.compile<ClinicalDraftDocument>(
  clinicalDraftV2Schema,
);
const validateClinicalDraftV3Schema = ajv.compile<ClinicalDraftDocument>(
  clinicalDraftV3Schema,
);
const validateClinicalDraftV4Schema = ajv.compile<ClinicalDraftDocument>(
  clinicalDraftV4Schema,
);
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export function validateEncounterMarkdown(
  bytes: Uint8Array,
  source = "<memory>",
): EncounterDocument {
  const document = splitFrontmatter(bytes, source);
  if (document.body !== "") {
    throw validationError(
      source,
      "/body",
      "clinical_document.encounter_body",
      "o encontro deste perfil não contém corpo Markdown",
    );
  }
  const parsed = parseYamlSubset(document.yaml, source);
  if (!validateEncounterSchema(parsed)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateEncounterSchema.errors ?? []),
    );
  }
  return parsed as EncounterDocument;
}

export function validateClinicalDraftMarkdown(
  bytes: Uint8Array,
  source = "<memory>",
): ParsedClinicalDraft {
  const document = splitFrontmatter(bytes, source);
  if (!document.body.startsWith("\n") || !document.body.endsWith("\n")) {
    throw validationError(
      source,
      "/body",
      "clinical_document.draft_body",
      "o rascunho exige uma linha vazia após o frontmatter e LF final",
    );
  }
  const parsed = parseYamlSubset(document.yaml, source);
  const schema = (parsed as { schema?: unknown }).schema;
  const validate = schema === "openpep/clinical-note@4"
    ? validateClinicalDraftV4Schema
    : schema === "openpep/clinical-note@3"
    ? validateClinicalDraftV3Schema
    : schema === "openpep/clinical-note@2"
    ? validateClinicalDraftV2Schema
    : validateClinicalDraftSchema;
  if (!validate(parsed)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validate.errors ?? []),
    );
  }
  const metadata = parsed as ClinicalDraftDocument;
  if (metadata.schema === "openpep/clinical-note@3") {
    validateV3GenerationLinks(metadata, source);
  } else if (metadata.schema === "openpep/clinical-note@4") {
    validateV4GenerationLinks(metadata, source);
  }
  return {
    metadata,
    body: document.body.slice(1),
  };
}

export function bindClinicalDraft(
  encounter: EncounterDocument,
  draft: ClinicalDraftDocument,
  expectedPatientId: string,
  source = "<memory>",
): void {
  if (encounter.patient_id !== expectedPatientId) {
    throw validationError(
      source,
      "/patient_id",
      "clinical_document.patient_mismatch",
      "o encontro pertence a outro diretório de paciente",
    );
  }
  if (draft.patient_id !== encounter.patient_id) {
    throw validationError(
      source,
      "/patient_id",
      "clinical_document.patient_mismatch",
      "o rascunho pertence a outro paciente",
    );
  }
  if (draft.encounter_id !== encounter.encounter_id) {
    throw validationError(
      source,
      "/encounter_id",
      "clinical_document.encounter_mismatch",
      "o rascunho pertence a outro encontro",
    );
  }
  if (draft.author_id !== encounter.created_by) {
    throw validationError(
      source,
      "/author_id",
      "clinical_document.author_mismatch",
      "a identidade sintética diverge entre encontro e rascunho",
    );
  }
  if (draft.schema === "openpep/clinical-note@2" &&
      draft.ai_assistance.reviewed_by !== draft.author_id) {
    throw validationError(
      source,
      "/ai_assistance/reviewed_by",
      "clinical_document.reviewer_mismatch",
      "o revisor humano deve ser o autor do rascunho neste perfil",
    );
  }
  if (draft.schema === "openpep/clinical-note@3" ||
      draft.schema === "openpep/clinical-note@4") {
    const mismatched = draft.ai_assistance.generations.findIndex((generation) =>
      generation.accepted_by !== draft.author_id
    );
    if (mismatched >= 0) {
      throw validationError(
        source,
        `/ai_assistance/generations/${mismatched}/accepted_by`,
        "clinical_document.reviewer_mismatch",
        "o autor da aceitação deve ser o autor do rascunho neste perfil",
      );
    }
  }
}

function validateV4GenerationLinks(
  draft: ClinicalDraftV4Document,
  source: string,
): void {
  const generationIDs = draft.ai_assistance.generations.map((item) =>
    item.generation_id
  );
  if (new Set(generationIDs).size !== generationIDs.length) {
    throw validationError(
      source,
      "/ai_assistance/generations",
      "clinical_document.duplicate_generation",
      "cada geração aceita deve possuir identificador único",
    );
  }
  const invalidProfile = draft.ai_assistance.generations.findIndex((item) => {
    if (item.provenance_schema === "openpep/patient-ai-provenance@1") {
      return item.engine !== "openai/responses" || item.accepted_at === null ||
        item.model === null || item.response_id === null;
    }
    if (item.provenance_schema === "openpep/consultation-summary-provenance@1") {
      return item.engine !== "apple/FoundationModels.SystemLanguageModel" ||
        item.model !== null || item.response_id !== null ||
        item.prompt_version !== "openpep/consultation-summary-pt-BR@1" ||
        item.locale !== "pt-BR" || item.generated_at === null ||
        item.chunk_count === null;
    }
    const progressivePrompt = item.prompt_version ===
        "openpep/progressive-consultation-summary-pt-BR@1" ||
      item.prompt_version === "openpep/progressive-consultation-summary-pt-BR@2" ||
      item.prompt_version === "openpep/progressive-consultation-summary-pt-BR@3" ||
      item.prompt_version === "openpep/progressive-consultation-summary-pt-BR@4" ||
      item.prompt_version === "openpep/progressive-consultation-summary-pt-BR@5";
    const finalApplePrompt = item.prompt_version ===
      "openpep/final-consultation-summary-apple-pt-BR@1";
    const shared = item.accepted_at === null || item.generated_at === null ||
      (!progressivePrompt && !finalApplePrompt) ||
      item.locale !== "pt-BR" || item.chunk_count === null || item.chunk_count < 1;
    if (item.engine === "apple/FoundationModels.SystemLanguageModel") {
      return shared || item.model !== null || item.response_id !== null;
    }
    return shared || finalApplePrompt || item.engine !== "openai/responses" || item.model === null ||
      item.response_id === null;
  });
  if (invalidProfile >= 0) {
    throw validationError(
      source,
      `/ai_assistance/generations/${invalidProfile}`,
      "clinical_document.ai_provenance_profile",
      "a geração não corresponde ao perfil de resumo progressivo declarado",
    );
  }
  const generationSources = draft.ai_assistance.generations.map((item) =>
    item.source_id
  );
  if (new Set(generationSources).size !== generationSources.length ||
      generationSources.length !== draft.source_ids.length ||
      generationSources.some((sourceID, index) => draft.source_ids[index] !== sourceID)) {
    throw validationError(
      source,
      "/source_ids",
      "clinical_document.ai_source_set_mismatch",
      "as fontes do rascunho devem corresponder uma a uma às gerações aceitas",
    );
  }
}

function validateV3GenerationLinks(
  draft: ClinicalDraftV3Document,
  source: string,
): void {
  const generationIDs = draft.ai_assistance.generations.map((item) =>
    item.generation_id
  );
  if (new Set(generationIDs).size !== generationIDs.length) {
    throw validationError(
      source,
      "/ai_assistance/generations",
      "clinical_document.duplicate_generation",
      "cada geração aceita deve possuir identificador único",
    );
  }
  const invalidProfile = draft.ai_assistance.generations.findIndex((item) => {
    if (item.provenance_schema === "openpep/patient-ai-provenance@1") {
      return item.engine !== "openai/responses" || item.accepted_at === null ||
        item.model === null || item.response_id === null;
    }
    return item.engine !== "apple/FoundationModels.SystemLanguageModel" ||
      item.model !== null || item.response_id !== null ||
      item.prompt_version !== "openpep/consultation-summary-pt-BR@1" ||
      item.locale !== "pt-BR" || item.generated_at === null ||
      item.chunk_count === null;
  });
  if (invalidProfile >= 0) {
    throw validationError(
      source,
      `/ai_assistance/generations/${invalidProfile}`,
      "clinical_document.ai_provenance_profile",
      "a geração não corresponde ao perfil de proveniência declarado",
    );
  }
  const generationSources = draft.ai_assistance.generations.map((item) =>
    item.source_id
  );
  if (new Set(generationSources).size !== generationSources.length ||
      generationSources.length !== draft.source_ids.length ||
      generationSources.some((sourceID, index) => draft.source_ids[index] !== sourceID)) {
    throw validationError(
      source,
      "/source_ids",
      "clinical_document.ai_source_set_mismatch",
      "as fontes do rascunho devem corresponder uma a uma às gerações aceitas",
    );
  }
}

function splitFrontmatter(
  bytes: Uint8Array,
  source: string,
): { readonly yaml: string; readonly body: string } {
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb &&
      bytes[2] === 0xbf) {
    throw validationError(source, "/", "yaml.bom", "UTF-8 BOM não é permitido");
  }

  let text: string;
  try {
    text = utf8Decoder.decode(bytes);
  } catch {
    throw validationError(
      source,
      "/",
      "yaml.utf8",
      "o documento não contém UTF-8 válido",
    );
  }
  if (text.includes("\r")) {
    throw validationError(
      source,
      "/",
      "yaml.line_endings",
      "somente quebras de linha LF são permitidas",
    );
  }
  if (text.normalize("NFC") !== text) {
    throw validationError(
      source,
      "/",
      "yaml.unicode_nfc",
      "o documento deve usar Unicode NFC",
    );
  }
  if (!text.startsWith("---\n")) {
    throw validationError(
      source,
      "/",
      "clinical_document.frontmatter",
      "o documento deve começar com frontmatter YAML",
    );
  }
  const closing = text.indexOf("---\n", 4);
  if (closing < 0 || (closing > 4 && text[closing - 1] !== "\n")) {
    throw validationError(
      source,
      "/",
      "clinical_document.frontmatter",
      "o frontmatter não possui delimitador final",
    );
  }
  return {
    yaml: text.slice(4, closing),
    body: text.slice(closing + 4),
  };
}
