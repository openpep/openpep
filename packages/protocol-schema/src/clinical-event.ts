// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { canonicalizeJson, type JsonValue } from "./canonical.js";
import { ProtocolValidationError } from "./errors.js";
import { createProtocolAjv, schemaIssues } from "./schema-validation.js";

export interface ClinicalEventBody {
  readonly schema: "openpep/clinical-event@1";
  readonly event_id: string;
  readonly sequence: number;
  readonly patient_id: string;
  readonly event_type: string;
  readonly object_id: string;
  readonly relative_path: string;
  readonly object_sha256: string;
  readonly actor_id: string;
  readonly device_id: string;
  readonly signing_key_id: string;
  readonly occurred_at: string;
  readonly previous_event_hash: string;
  readonly [extension: `x_${string}`]: JsonValue;
}

export interface ClinicalLedgerEvent extends ClinicalEventBody {
  readonly event_hash: string;
  readonly signature: string;
}

const schemaUrl = new URL(
  "../../schemas/v1/clinical-event.schema.json",
  import.meta.url,
);
const clinicalEventSchema = JSON.parse(
  readFileSync(schemaUrl, "utf8"),
) as object;
const ajv = createProtocolAjv();
const validateClinicalEventSchema = ajv.compile<ClinicalLedgerEvent>(
  clinicalEventSchema,
);

export function validateClinicalEvent(
  value: unknown,
  source = "<clinical-event>",
): ClinicalLedgerEvent {
  canonicalizeJson(value, source);
  if (!validateClinicalEventSchema(value)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateClinicalEventSchema.errors ?? []),
    );
  }
  return value;
}

export function eventHashBody(
  event: ClinicalLedgerEvent,
): ClinicalEventBody {
  const body: Record<string, JsonValue> = {};
  for (const [key, value] of Object.entries(event)) {
    if (key !== "event_hash" && key !== "signature") {
      body[key] = value as JsonValue;
    }
  }
  return body as unknown as ClinicalEventBody;
}
