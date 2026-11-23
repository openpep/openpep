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

export interface AppointmentManifest {
  readonly schema: "openpep/appointment@1";
  readonly appointment_id: string;
  readonly patient_id: string;
  readonly starts_at: string;
  readonly ends_at: string;
  readonly time_zone: string;
  readonly modality: "in_person" | "telemedicine";
  readonly status:
    | "scheduled"
    | "arrived"
    | "in_progress"
    | "completed"
    | "cancelled"
    | "no_show";
  readonly location: string | null;
  readonly remote_access_url: string | null;
  readonly administrative_note: string | null;
  readonly encounter_id: string | null;
  readonly created_at: string;
  readonly updated_at: string;
  readonly [extension: `x_${string}`]: unknown;
}

const schemaUrl = new URL(
  "../../schemas/v1/appointment.schema.json",
  import.meta.url,
);
const appointmentSchema = JSON.parse(readFileSync(schemaUrl, "utf8")) as object;
const ajv = createProtocolAjv();
const validateSchema = ajv.compile<AppointmentManifest>(appointmentSchema);

export function validateAppointmentYaml(
  sourceText: string,
  source = "<memory>",
): AppointmentManifest {
  const parsed = parseYamlSubset(sourceText, source);
  if (!validateSchema(parsed)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateSchema.errors ?? []),
    );
  }
  const appointment = parsed as AppointmentManifest;
  validateAppointmentState(appointment, source);
  return appointment;
}

export async function readAppointmentManifest(
  filePath: string,
): Promise<AppointmentManifest> {
  const bytes = await readFile(filePath);
  return validateAppointmentYaml(decodeYamlBytes(bytes, filePath), filePath);
}

export function bindAppointmentManifestToFile(
  appointment: AppointmentManifest,
  fileName: string,
  source = "appointment.yaml",
): AppointmentManifest {
  if (`${appointment.appointment_id}.yaml` !== basename(fileName)) {
    throw validationError(
      source,
      "/appointment_id",
      "appointment.appointment_id_mismatch",
      "appointment_id deve corresponder ao nome do arquivo",
    );
  }
  return appointment;
}

function validateAppointmentState(
  appointment: AppointmentManifest,
  source: string,
): void {
  if (compareUtcRfc3339(appointment.ends_at, appointment.starts_at) <= 0) {
    throw validationError(
      source,
      "/ends_at",
      "appointment.invalid_interval",
      "ends_at deve ser posterior a starts_at",
    );
  }
  if (compareUtcRfc3339(appointment.updated_at, appointment.created_at) < 0) {
    throw validationError(
      source,
      "/updated_at",
      "appointment.updated_before_created",
      "updated_at não pode ser anterior a created_at",
    );
  }
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: appointment.time_zone });
  } catch {
    throw validationError(
      source,
      "/time_zone",
      "appointment.invalid_time_zone",
      "time_zone deve identificar um fuso IANA disponível",
    );
  }
}
