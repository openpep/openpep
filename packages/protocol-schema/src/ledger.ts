// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import {
  calculateClinicalEventHash,
  canonicalizeJson,
  sha256Hex,
} from "./canonical.js";
import {
  eventHashBody,
  type ClinicalLedgerEvent,
  validateClinicalEvent,
} from "./clinical-event.js";
import {
  ProtocolValidationError,
  type ProtocolValidationIssue,
  validationError,
} from "./errors.js";
import { isOpenPepId } from "./ids.js";
import { verifyEs256EventHashSignature } from "./signatures.js";
import {
  findAuthorizedSigningKey,
  type SigningKeyRegistry,
  validateSigningKeyRegistry,
} from "./signing-keys.js";

export const zeroEventHash = "0".repeat(64);
export const maximumLedgerLineBytes = 1024 * 1024;

export interface ParsedClinicalLedgerEvent {
  readonly event: ClinicalLedgerEvent;
  readonly lineNumber: number;
}

export interface ClinicalLedgerCheckpointExpectation {
  readonly patientId: string;
  readonly eventCount: number;
  readonly headEventHash: string;
}

export type ClinicalObjectResolver = (
  relativePath: string,
  event: ClinicalLedgerEvent,
) => Uint8Array | undefined | Promise<Uint8Array | undefined>;

export interface ClinicalLedgerVerificationOptions {
  readonly checkpoint?: ClinicalLedgerCheckpointExpectation;
  readonly resolveObject?: ClinicalObjectResolver;
  readonly signaturePolicy?: "required" | "not_checked";
  readonly signingKeyRegistry?: SigningKeyRegistry;
}

export interface ClinicalLedgerVerification {
  readonly patientId: string | null;
  readonly eventCount: number;
  readonly headEventHash: string;
  readonly objectsVerified: number;
  readonly signatures: "verified" | "not_checked";
  readonly signaturesVerified: number;
}

const lowercaseSha256Pattern = /^[0-9a-f]{64}$/;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export function decodeClinicalLedgerBytes(
  bytes: Uint8Array,
  source = "<ledger.ndjson>",
): string {
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb &&
      bytes[2] === 0xbf) {
    throw validationError(
      source,
      "/",
      "ledger.bom",
      "o ledger deve usar UTF-8 sem BOM",
    );
  }

  try {
    return utf8Decoder.decode(bytes);
  } catch {
    throw validationError(
      source,
      "/",
      "ledger.utf8",
      "o ledger contém uma sequência UTF-8 inválida",
    );
  }
}

export function parseClinicalLedgerNdjson(
  sourceText: string,
  source = "<ledger.ndjson>",
): readonly ParsedClinicalLedgerEvent[] {
  if (sourceText.length === 0) {
    return [];
  }
  if (sourceText.includes("\r")) {
    throw validationError(
      source,
      "/",
      "ledger.crlf",
      "o ledger deve usar somente quebras de linha LF",
    );
  }
  if (!sourceText.endsWith("\n")) {
    throw validationError(
      source,
      "/",
      "ledger.truncated_line",
      "um ledger não vazio deve terminar com LF",
    );
  }

  const lines = sourceText.slice(0, -1).split("\n");
  return lines.map((line, index) => parseLedgerLine(line, index + 1, source));
}

export async function verifyClinicalLedgerBytes(
  bytes: Uint8Array,
  options: ClinicalLedgerVerificationOptions = {},
  source = "<ledger.ndjson>",
): Promise<ClinicalLedgerVerification> {
  const sourceText = decodeClinicalLedgerBytes(bytes, source);
  const parsedEvents = parseClinicalLedgerNdjson(sourceText, source);
  validateCheckpoint(options.checkpoint, source);
  const signaturePolicy = options.signaturePolicy ?? "required";
  if (signaturePolicy !== "required" && signaturePolicy !== "not_checked") {
    throw validationError(
      source,
      "/signaturePolicy",
      "ledger.signature_policy",
      "signaturePolicy deve ser required ou not_checked",
    );
  }
  const signingKeyRegistry = options.signingKeyRegistry === undefined
    ? undefined
    : validateSigningKeyRegistry(
      options.signingKeyRegistry,
      `${source}:signing-key-registry`,
    );
  if (signaturePolicy === "required" && parsedEvents.length > 0 &&
      signingKeyRegistry === undefined) {
    throw validationError(
      source,
      "/signingKeyRegistry",
      "ledger.signing_key_registry",
      "a verificação de assinaturas exige um registro confiável de chaves",
    );
  }

  let patientId: string | null = options.checkpoint?.patientId ?? null;
  let expectedPreviousHash = zeroEventHash;
  let objectsVerified = 0;
  let signaturesVerified = 0;
  const eventIds = new Set<string>();
  let previousOccurredAt = Number.NEGATIVE_INFINITY;

  for (let index = 0; index < parsedEvents.length; index += 1) {
    const parsed = parsedEvents[index];
    if (parsed === undefined) {
      continue;
    }
    const { event, lineNumber } = parsed;
    const basePath = `/lines/${lineNumber}`;
    const expectedSequence = index + 1;

    if (event.sequence !== expectedSequence) {
      throw validationError(
        source,
        `${basePath}/sequence`,
        "ledger.sequence",
        `a sequência esperada é ${expectedSequence}`,
      );
    }
    if (eventIds.has(event.event_id)) {
      throw validationError(
        source,
        `${basePath}/event_id`,
        "ledger.duplicate_event_id",
        "event_id já apareceu neste ledger",
      );
    }
    eventIds.add(event.event_id);

    // Keys are authorized by occurred_at; a later event dated before an earlier one could hide behind a revoked key's window.
    const occurredAt = Date.parse(event.occurred_at);
    if (!(occurredAt >= previousOccurredAt)) {
      throw validationError(
        source,
        `${basePath}/occurred_at`,
        "ledger.occurred_at_order",
        "occurred_at não pode ser anterior ao do evento anterior",
      );
    }
    previousOccurredAt = occurredAt;

    if (patientId === null) {
      patientId = event.patient_id;
    } else if (event.patient_id !== patientId) {
      throw validationError(
        source,
        `${basePath}/patient_id`,
        "ledger.patient_id",
        "todos os eventos devem pertencer ao mesmo paciente",
      );
    }

    if (event.previous_event_hash !== expectedPreviousHash) {
      throw validationError(
        source,
        `${basePath}/previous_event_hash`,
        "ledger.previous_event_hash",
        "o hash anterior não corresponde ao evento precedente",
      );
    }

    const calculatedHash = calculateClinicalEventHash(
      eventHashBody(event),
      source,
    ).eventHash;
    if (event.event_hash !== calculatedHash) {
      throw validationError(
        source,
        `${basePath}/event_hash`,
        "ledger.event_hash",
        "event_hash não corresponde ao conteúdo do evento",
      );
    }

    if (signaturePolicy === "required") {
      const key = findAuthorizedSigningKey(
        signingKeyRegistry as SigningKeyRegistry,
        event.signing_key_id,
        event.device_id,
        event.occurred_at,
        source,
        `${basePath}/signing_key_id`,
      );
      verifyEs256EventHashSignature(
        event.event_hash,
        event.signature,
        key.public_key_x963,
        source,
        `${basePath}/signature`,
      );
      signaturesVerified += 1;
    }

    if (options.resolveObject !== undefined) {
      const objectBytes = await resolveObject(
        options.resolveObject,
        event,
        source,
        basePath,
      );
      if (sha256Hex(objectBytes) !== event.object_sha256) {
        throw validationError(
          source,
          `${basePath}/object_sha256`,
          "ledger.object_hash",
          "o objeto referido não corresponde ao hash registrado",
        );
      }
      objectsVerified += 1;
    }

    expectedPreviousHash = event.event_hash;
  }

  if (options.checkpoint !== undefined) {
    if (parsedEvents.length !== options.checkpoint.eventCount) {
      throw validationError(
        source,
        "/checkpoint/eventCount",
        "ledger.checkpoint_count",
        "a quantidade de eventos não corresponde ao checkpoint",
      );
    }
    if (expectedPreviousHash !== options.checkpoint.headEventHash) {
      throw validationError(
        source,
        "/checkpoint/headEventHash",
        "ledger.checkpoint_hash",
        "o hash final não corresponde ao checkpoint",
      );
    }
  }

  return {
    patientId,
    eventCount: parsedEvents.length,
    headEventHash: expectedPreviousHash,
    objectsVerified,
    signatures: signaturePolicy === "required" ? "verified" : "not_checked",
    signaturesVerified,
  };
}

function parseLedgerLine(
  line: string,
  lineNumber: number,
  source: string,
): ParsedClinicalLedgerEvent {
  const basePath = `/lines/${lineNumber}`;
  if (line.length === 0) {
    throw validationError(
      source,
      basePath,
      "ledger.blank_line",
      "linhas vazias não são permitidas",
    );
  }
  if (Buffer.byteLength(line, "utf8") > maximumLedgerLineBytes) {
    throw validationError(
      source,
      basePath,
      "ledger.line_too_large",
      `a linha excede ${maximumLedgerLineBytes} bytes`,
    );
  }

  let value: unknown;
  try {
    value = JSON.parse(line) as unknown;
  } catch {
    throw validationError(
      source,
      basePath,
      "ledger.json_syntax",
      "a linha não contém um objeto JSON válido",
    );
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw validationError(
      source,
      basePath,
      "ledger.root_object",
      "cada linha deve conter um objeto JSON",
    );
  }

  let canonicalText: string;
  try {
    canonicalText = canonicalizeJson(value, source).text;
  } catch (error) {
    throw prefixValidationError(error, source, basePath);
  }
  if (line !== canonicalText) {
    throw validationError(
      source,
      basePath,
      "ledger.non_canonical_line",
      "a linha deve estar na representação canônica RFC 8785",
    );
  }

  let event: ClinicalLedgerEvent;
  try {
    event = validateClinicalEvent(value, source);
  } catch (error) {
    throw prefixValidationError(error, source, basePath);
  }
  return { event, lineNumber };
}

function prefixValidationError(
  error: unknown,
  source: string,
  basePath: string,
): ProtocolValidationError {
  if (!(error instanceof ProtocolValidationError)) {
    throw error;
  }
  const issues: ProtocolValidationIssue[] = error.issues.map((issue) => ({
    ...issue,
    source,
    path: issue.path === "/" ? basePath : `${basePath}${issue.path}`,
  }));
  return new ProtocolValidationError(issues);
}

function validateCheckpoint(
  checkpoint: ClinicalLedgerCheckpointExpectation | undefined,
  source: string,
): void {
  if (checkpoint === undefined) {
    return;
  }
  if (!isOpenPepId(checkpoint.patientId, "patient")) {
    throw validationError(
      source,
      "/checkpoint/patientId",
      "ledger.checkpoint_patient_id",
      "o checkpoint deve identificar um paciente OpenPEP válido",
    );
  }
  if (!Number.isSafeInteger(checkpoint.eventCount) || checkpoint.eventCount < 0) {
    throw validationError(
      source,
      "/checkpoint/eventCount",
      "ledger.checkpoint_count",
      "eventCount deve ser um inteiro seguro não negativo",
    );
  }
  if (!lowercaseSha256Pattern.test(checkpoint.headEventHash)) {
    throw validationError(
      source,
      "/checkpoint/headEventHash",
      "ledger.checkpoint_hash",
      "headEventHash deve conter SHA-256 hexadecimal minúsculo",
    );
  }
}

async function resolveObject(
  resolver: ClinicalObjectResolver,
  event: ClinicalLedgerEvent,
  source: string,
  basePath: string,
): Promise<Uint8Array> {
  let bytes: Uint8Array | undefined;
  try {
    bytes = await resolver(event.relative_path, event);
  } catch {
    throw validationError(
      source,
      `${basePath}/relative_path`,
      "ledger.object_unreadable",
      "o objeto referido não pôde ser lido",
    );
  }
  if (bytes === undefined) {
    throw validationError(
      source,
      `${basePath}/relative_path`,
      "ledger.object_missing",
      "o objeto referido não foi encontrado",
    );
  }
  return bytes;
}
