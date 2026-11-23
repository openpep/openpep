// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { canonicalizeJson, type JsonValue } from "./canonical.js";
import { ProtocolValidationError } from "./errors.js";
import type { ClinicalLedgerCheckpointExpectation } from "./ledger.js";
import { createProtocolAjv, schemaIssues } from "./schema-validation.js";

export interface ClinicalLedgerCheckpoint {
  readonly schema: "openpep/clinical-ledger-checkpoint@1";
  readonly patient_id: string;
  readonly event_count: number;
  readonly head_event_hash: string;
  readonly [extension: `x_${string}`]: JsonValue;
}

const schemaUrl = new URL(
  "../../schemas/v1/clinical-ledger-checkpoint.schema.json",
  import.meta.url,
);
const checkpointSchema = JSON.parse(readFileSync(schemaUrl, "utf8")) as object;
const ajv = createProtocolAjv();
const validateCheckpointSchema = ajv.compile<ClinicalLedgerCheckpoint>(
  checkpointSchema,
);

export function validateClinicalLedgerCheckpoint(
  value: unknown,
  source = "<clinical-ledger-checkpoint>",
): ClinicalLedgerCheckpoint {
  canonicalizeJson(value, source);
  if (!validateCheckpointSchema(value)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateCheckpointSchema.errors ?? []),
    );
  }
  return value;
}

export function checkpointExpectation(
  checkpoint: ClinicalLedgerCheckpoint,
): ClinicalLedgerCheckpointExpectation {
  return {
    patientId: checkpoint.patient_id,
    eventCount: checkpoint.event_count,
    headEventHash: checkpoint.head_event_hash,
  };
}
