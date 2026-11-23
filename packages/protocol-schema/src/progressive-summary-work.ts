// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { ProtocolValidationError, validationError } from "./errors.js";
import { createProtocolAjv, compareUtcRfc3339, schemaIssues } from "./schema-validation.js";

export type ProgressiveSummaryWorkStatus =
  | "preparing" | "recording" | "transcribing" | "draining" | "ready"
  | "incomplete" | "failed";

export interface ProgressiveSummaryRange {
  readonly start_seconds: number;
  readonly end_seconds: number;
  readonly is_approximate: boolean;
}

export interface ProgressiveSummarySegmentReference {
  readonly segment_id: string;
  readonly revision: number;
}

export interface ProgressiveSummarySegment {
  readonly id: string;
  readonly revision: number;
  readonly range: ProgressiveSummaryRange;
  readonly text: string;
  readonly engine: string;
  readonly model: string;
  readonly attempt_id: string;
}

export interface ProgressiveSummaryGeneration {
  readonly generation_id: string;
  readonly engine: string;
  readonly model: string | null;
  readonly response_id: string | null;
  readonly prompt_version: string;
  readonly generated_at: string;
  readonly source: string;
  readonly segment_references: readonly ProgressiveSummarySegmentReference[];
}

export interface ProgressiveSummaryAcceptance {
  readonly acceptance_id: string;
  readonly accepted_by: string;
  readonly accepted_at: string;
  readonly accepted_text: string;
  readonly source_asset_id: string;
}

export interface ProgressiveSummaryBlock {
  readonly id: string;
  readonly kind: "interval" | "correction" | "consolidated";
  readonly range: ProgressiveSummaryRange;
  readonly subject: string;
  readonly generated_text: string;
  readonly edited_text: string;
  readonly state: "new" | "edited" | "added" | "needs_review";
  readonly generation: ProgressiveSummaryGeneration;
  readonly acceptance: ProgressiveSummaryAcceptance | null;
}

export interface ProgressiveSummaryItem {
  readonly id: string;
  readonly text: string;
  readonly state: "proposed" | "professional" | "needs_review";
  readonly segment_references: readonly ProgressiveSummarySegmentReference[];
}

export interface ProgressiveSummaryRevision {
  readonly id: string;
  readonly sequence: number;
  readonly base_revision: number;
  readonly saved_at: string;
  readonly origin: "model" | "professional";
  readonly kind: "update" | "no_change";
  readonly affected_item_ids: readonly string[];
  readonly segment_references: readonly ProgressiveSummarySegmentReference[];
  readonly before_text: string;
  readonly after_text: string;
  readonly computed_diff: string;
  readonly generation: ProgressiveSummaryGeneration | null;
}

export interface ProgressiveIncrementalSummary {
  readonly revision: number;
  readonly covered_segment_references: readonly ProgressiveSummarySegmentReference[];
  readonly items: readonly ProgressiveSummaryItem[];
  readonly revisions: readonly ProgressiveSummaryRevision[];
  readonly acceptance: ProgressiveSummaryAcceptance | null;
}

export interface ProgressiveSummaryWorkDocument {
  readonly schema: "openpep/progressive-summary-work@1" | "openpep/progressive-summary-work@2";
  readonly session_id: string;
  readonly vault_id: string;
  readonly patient_id: string;
  readonly encounter_id: string;
  readonly created_at: string;
  readonly updated_at: string;
  readonly summary_interval_seconds: number;
  readonly capture: {
    readonly source: "imported" | "microphone" | "telecall";
    readonly status: ProgressiveSummaryWorkStatus;
    readonly attempt_id: string;
    readonly started_at: string | null;
    readonly ended_at: string | null;
    readonly captured_seconds: number;
    readonly audio_filename: string | null;
    readonly audio_filenames?: readonly string[];
  };
  readonly transcription_engine: string;
  readonly transcription_model: string;
  readonly summary_engine: string;
  readonly summary_model: string | null;
  readonly segments: readonly ProgressiveSummarySegment[];
  readonly blocks: readonly ProgressiveSummaryBlock[];
  readonly summary?: ProgressiveIncrementalSummary;
  readonly pending_ranges: readonly ProgressiveSummaryRange[];
  readonly status: ProgressiveSummaryWorkStatus;
  readonly last_error: string | null;
}

export interface ProgressiveSummaryWorkBinding {
  readonly vault_id: string;
  readonly patient_id: string;
  readonly encounter_id: string;
}

const schemaV1 = JSON.parse(readFileSync(new URL(
  "../../schemas/v1/progressive-summary-work.schema.json",
  import.meta.url,
), "utf8")) as object;
const schemaV2 = JSON.parse(readFileSync(new URL(
  "../../schemas/v2/progressive-summary-work.schema.json",
  import.meta.url,
), "utf8")) as object;
const ajv = createProtocolAjv();
const validateSchemaV1 = ajv.compile<ProgressiveSummaryWorkDocument>(schemaV1);
const validateSchemaV2 = ajv.compile<ProgressiveSummaryWorkDocument>(schemaV2);
const decoder = new TextDecoder("utf-8", { fatal: true });

export function validateProgressiveSummaryWork(
  value: unknown,
  source = "<memory>",
): ProgressiveSummaryWorkDocument {
  const version = typeof value === "object" && value !== null && "schema" in value
    ? (value as { schema?: unknown }).schema : undefined;
  const validateSchema = version === "openpep/progressive-summary-work@2"
    ? validateSchemaV2 : validateSchemaV1;
  if (!validateSchema(value)) {
    throw new ProtocolValidationError(schemaIssues(source, validateSchema.errors ?? []));
  }
  const document = value as ProgressiveSummaryWorkDocument;
  validateSemantics(document, source);
  return document;
}

export function validateProgressiveSummaryWorkJson(
  bytes: Uint8Array,
  source = "<memory>",
): ProgressiveSummaryWorkDocument {
  let text: string;
  try {
    text = decoder.decode(bytes);
  } catch {
    throw validationError(source, "/", "progressive_summary_work.invalid_utf8", "o documento deve usar UTF-8 válido");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw validationError(source, "/", "progressive_summary_work.invalid_json", "o documento deve conter JSON válido");
  }
  return validateProgressiveSummaryWork(value, source);
}

export function bindProgressiveSummaryWork(
  document: ProgressiveSummaryWorkDocument,
  binding: ProgressiveSummaryWorkBinding,
  source = "progressive-summary-work.json",
): ProgressiveSummaryWorkDocument {
  for (const key of ["vault_id", "patient_id", "encounter_id"] as const) {
    if (document[key] !== binding[key]) {
      throw validationError(source, `/${key}`, "progressive_summary_work.binding_mismatch", `${key} deve corresponder à consulta vinculada`);
    }
  }
  return document;
}

function validateSemantics(document: ProgressiveSummaryWorkDocument, source: string): void {
  if (compareUtcRfc3339(document.updated_at, document.created_at) < 0) {
    fail(source, "/updated_at", "updated_before_created");
  }
  const audioFiles = document.capture.audio_filenames;
  if (audioFiles !== undefined && audioFiles.at(-1) !== document.capture.audio_filename) {
    fail(source, "/capture/audio_filenames", "capture_audio_filename_mismatch");
  }
  if (document.capture.started_at !== null && document.capture.ended_at !== null &&
      compareUtcRfc3339(document.capture.ended_at, document.capture.started_at) < 0) {
    fail(source, "/capture/ended_at", "capture_ended_before_started");
  }

  const segmentIDs = new Set<string>();
  const segmentKeys = new Set<string>();
  let previousEnd = 0;
  for (const [index, segment] of document.segments.entries()) {
    const path = `/segments/${index}`;
    validRange(segment.range, `${path}/range`, source);
    if (segment.range.start_seconds < previousEnd) fail(source, `${path}/range/start_seconds`, "segment_out_of_order");
    previousEnd = segment.range.end_seconds;
    if (segment.attempt_id !== document.capture.attempt_id) fail(source, `${path}/attempt_id`, "segment_attempt_mismatch");
    if (segmentIDs.has(segment.id)) fail(source, `${path}/id`, "duplicate_segment_id");
    segmentIDs.add(segment.id);
    segmentKeys.add(`${segment.id}\u0000${segment.revision}`);
    safeText(segment.text, 200_000, `${path}/text`, source);
    safeProvider(segment.engine, `${path}/engine`, source);
    safeProvider(segment.model, `${path}/model`, source);
  }

  const blockIDs = new Set<string>();
  const generationIDs = new Set<string>();
  const acceptanceIDs = new Set<string>();
  for (const [index, block] of document.blocks.entries()) {
    const path = `/blocks/${index}`;
    validRange(block.range, `${path}/range`, source);
    if (blockIDs.has(block.id)) fail(source, `${path}/id`, "duplicate_block_id");
    blockIDs.add(block.id);
    if (generationIDs.has(block.generation.generation_id)) fail(source, `${path}/generation/generation_id`, "duplicate_generation_id");
    generationIDs.add(block.generation.generation_id);
    safeText(block.subject, 200, `${path}/subject`, source);
    safeText(block.generated_text, 500_000, `${path}/generated_text`, source);
    safeText(block.edited_text, 500_000, `${path}/edited_text`, source);
    safeProvider(block.generation.engine, `${path}/generation/engine`, source);
    if (block.generation.model !== null) safeProvider(block.generation.model, `${path}/generation/model`, source);
    if (block.generation.response_id !== null) safeProvider(block.generation.response_id, `${path}/generation/response_id`, source);
    safeProvider(block.generation.prompt_version, `${path}/generation/prompt_version`, source);
    safeText(block.generation.source, 2_000_000, `${path}/generation/source`, source);
    for (const [referenceIndex, reference] of block.generation.segment_references.entries()) {
      if (!segmentKeys.has(`${reference.segment_id}\u0000${reference.revision}`)) {
        fail(source, `${path}/generation/segment_references/${referenceIndex}`, "unknown_segment_reference");
      }
    }
    if (block.state === "new" && block.edited_text !== block.generated_text) {
      fail(source, `${path}/edited_text`, "new_block_edited");
    }
    if (block.acceptance === null) {
      if (block.state === "added") fail(source, `${path}/acceptance`, "added_without_acceptance");
      continue;
    }
    if (block.state !== "added") fail(source, `${path}/state`, "acceptance_requires_added_state");
    if (acceptanceIDs.has(block.acceptance.acceptance_id)) fail(source, `${path}/acceptance/acceptance_id`, "duplicate_acceptance_id");
    acceptanceIDs.add(block.acceptance.acceptance_id);
    if (compareUtcRfc3339(block.acceptance.accepted_at, block.generation.generated_at) < 0) {
      fail(source, `${path}/acceptance/accepted_at`, "accepted_before_generated");
    }
    safeText(block.acceptance.accepted_text, 500_000, `${path}/acceptance/accepted_text`, source);
  }
  for (const [index, range] of document.pending_ranges.entries()) validRange(range, `/pending_ranges/${index}`, source);
  if (document.last_error !== null) safeText(document.last_error, 1_000, "/last_error", source);
  if (document.schema === "openpep/progressive-summary-work@2") {
    if (document.blocks.length !== 0 || document.summary === undefined) {
      fail(source, "/summary", "incremental_summary_required");
    }
    validateIncrementalSummary(document.summary, segmentKeys, source);
  }
}

function validateIncrementalSummary(
  summary: ProgressiveIncrementalSummary,
  segmentKeys: ReadonlySet<string>,
  source: string,
): void {
  const itemIDs = new Set<string>();
  for (const [index, item] of summary.items.entries()) {
    if (itemIDs.has(item.id)) fail(source, `/summary/items/${index}/id`, "duplicate_summary_item_id");
    itemIDs.add(item.id);
    safeText(item.text, 500_000, `/summary/items/${index}/text`, source);
    for (const [referenceIndex, reference] of item.segment_references.entries()) {
      if (!segmentKeys.has(`${reference.segment_id}\u0000${reference.revision}`)) {
        fail(source, `/summary/items/${index}/segment_references/${referenceIndex}`, "unknown_segment_reference");
      }
    }
  }
  const revisionIDs = new Set<string>();
  let expectedSequence = 1;
  for (const [index, revision] of summary.revisions.entries()) {
    const path = `/summary/revisions/${index}`;
    if (revisionIDs.has(revision.id)) fail(source, `${path}/id`, "duplicate_summary_revision_id");
    revisionIDs.add(revision.id);
    if (revision.sequence !== expectedSequence || revision.base_revision !== expectedSequence - 1) {
      fail(source, `${path}/sequence`, "summary_revision_out_of_order");
    }
    if ((revision.kind === "no_change") !== (revision.before_text === revision.after_text)) {
      fail(source, `${path}/kind`, "summary_revision_kind_mismatch");
    }
    if (revision.computed_diff !== summaryDiff(revision.before_text, revision.after_text)) {
      fail(source, `${path}/computed_diff`, "summary_revision_diff_mismatch");
    }
    if (revision.origin === "model" && revision.generation === null) {
      fail(source, `${path}/generation`, "model_revision_requires_generation");
    }
    if (revision.origin === "professional" && (revision.generation !== null || revision.kind === "no_change")) {
      fail(source, `${path}/generation`, "professional_revision_invalid");
    }
    for (const [referenceIndex, reference] of revision.segment_references.entries()) {
      if (!segmentKeys.has(`${reference.segment_id}\u0000${reference.revision}`)) {
        fail(source, `${path}/segment_references/${referenceIndex}`, "unknown_segment_reference");
      }
    }
    expectedSequence += 1;
  }
  if (summary.revision !== summary.revisions.length) {
    fail(source, "/summary/revision", "summary_revision_mismatch");
  }
  for (const [index, reference] of summary.covered_segment_references.entries()) {
    if (!segmentKeys.has(`${reference.segment_id}\u0000${reference.revision}`)) {
      fail(source, `/summary/covered_segment_references/${index}`, "unknown_segment_reference");
    }
  }
  const text = summary.items.map((item) => item.text).join("\n");
  if (text !== (summary.revisions.at(-1)?.after_text ?? "")) {
    fail(source, "/summary/items", "summary_text_revision_mismatch");
  }
  if (summary.acceptance !== null && summary.acceptance.accepted_text !== text) {
    fail(source, "/summary/acceptance/accepted_text", "summary_acceptance_mismatch");
  }
}

function summaryDiff(before: string, after: string): string {
  if (before === after) return "";
  const oldLines = before === "" ? [] : before.split("\n");
  const newLines = after === "" ? [] : after.split("\n");
  const changes: string[] = [];
  for (let index = 0; index < Math.max(oldLines.length, newLines.length); index += 1) {
    const oldLine = oldLines[index];
    const newLine = newLines[index];
    if (oldLine === newLine) continue;
    if (oldLine !== undefined) changes.push(`-${index + 1}: ${oldLine}`);
    if (newLine !== undefined) changes.push(`+${index + 1}: ${newLine}`);
  }
  return changes.join("\n");
}

function validRange(range: ProgressiveSummaryRange, path: string, source: string): void {
  if (range.end_seconds < range.start_seconds) fail(source, `${path}/end_seconds`, "invalid_range");
}

function safeProvider(value: string, path: string, source: string): void {
  if (Buffer.byteLength(value, "utf8") > 256 || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) fail(source, path, "unsafe_provider");
}

function safeText(value: string, maximum: number, path: string, source: string): void {
  if (value.trim().length === 0 || Buffer.byteLength(value, "utf8") > maximum || value !== value.normalize("NFC") || value.includes("\0")) {
    fail(source, path, "unsafe_text");
  }
}

function fail(source: string, path: string, rule: string): never {
  throw validationError(source, path, `progressive_summary_work.${rule}`, "o documento de trabalho não atende ao contrato");
}
