// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { ProtocolValidationError, validationError } from "./errors.js";
import {
  compareUtcRfc3339,
  createProtocolAjv,
  schemaIssues,
} from "./schema-validation.js";
import { decodeYamlBytes, parseYamlSubset } from "./yaml.js";

export interface PatientContact {
  readonly type: "phone" | "email";
  readonly value: string;
  readonly authorized_for_care: boolean;
}

export interface PatientIdentifier {
  readonly type: "cpf" | "other";
  readonly value: string;
}

export interface PatientAlert {
  readonly type: "allergy" | "critical";
  readonly description: string;
  readonly source: string;
  readonly recorded_at: string;
}

export interface PatientManifest {
  readonly schema: "openpep/patient@1";
  readonly patient_id: string;
  readonly status: "active" | "archived";
  readonly full_name: string | null;
  readonly preferred_name: string | null;
  readonly birth_date: string | null;
  readonly contacts: readonly PatientContact[];
  readonly identifiers: readonly PatientIdentifier[];
  readonly alerts: readonly PatientAlert[];
  readonly created_at: string;
  readonly updated_at: string;
  readonly archived_at: string | null;
  readonly [extension: `x_${string}`]: unknown;
}

const schemaUrl = new URL(
  "../../schemas/v1/patient.schema.json",
  import.meta.url,
);
const patientSchema = JSON.parse(readFileSync(schemaUrl, "utf8")) as object;
const ajv = createProtocolAjv();
const validateSchema = ajv.compile<PatientManifest>(patientSchema);

export function validatePatientYaml(
  sourceText: string,
  source = "<memory>",
): PatientManifest {
  const parsed = parseYamlSubset(sourceText, source);
  if (!validateSchema(parsed)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateSchema.errors ?? []),
    );
  }
  const patient = parsed as PatientManifest;
  validatePatientState(patient, source);
  return patient;
}

export async function readPatientManifest(
  filePath: string,
): Promise<PatientManifest> {
  const bytes = await readFile(filePath);
  return validatePatientYaml(decodeYamlBytes(bytes, filePath), filePath);
}

export function bindPatientManifestToDirectory(
  patient: PatientManifest,
  directoryName: string,
  source = "patient.yaml",
): PatientManifest {
  if (patient.patient_id !== basename(directoryName)) {
    throw validationError(
      source,
      "/patient_id",
      "patient.patient_id_mismatch",
      "patient_id deve corresponder ao diretório do paciente",
    );
  }
  return patient;
}

function validatePatientState(patient: PatientManifest, source: string): void {
  if (compareUtcRfc3339(patient.updated_at, patient.created_at) < 0) {
    throw validationError(
      source,
      "/updated_at",
      "patient.updated_before_created",
      "updated_at não pode ser anterior a created_at",
    );
  }
  if (patient.status === "active" && patient.archived_at !== null) {
    throw validationError(
      source,
      "/archived_at",
      "patient.active_with_archived_at",
      "paciente ativo deve ter archived_at nulo",
    );
  }
  if (patient.status === "archived" && patient.archived_at === null) {
    throw validationError(
      source,
      "/archived_at",
      "patient.archived_without_timestamp",
      "paciente arquivado deve ter archived_at",
    );
  }
  if (patient.archived_at !== null &&
      compareUtcRfc3339(patient.archived_at, patient.created_at) < 0) {
    throw validationError(
      source,
      "/archived_at",
      "patient.archived_before_created",
      "archived_at não pode ser anterior a created_at",
    );
  }
}
