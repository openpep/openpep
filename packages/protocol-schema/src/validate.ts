// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { ProtocolValidationError } from "./errors.js";
import { createProtocolAjv, schemaIssues } from "./schema-validation.js";
import { decodeYamlBytes, parseYamlSubset } from "./yaml.js";

export interface VaultManifest {
  readonly schema: "openpep/vault@1";
  readonly vault_id: string;
  readonly created_at: string;
  readonly protocol_version: "1.0";
  readonly clinical_writer: {
    readonly device_id: string;
    readonly [extension: `x_${string}`]: unknown;
  };
  readonly storage_mode: "local-portable";
  readonly encryption_mode: "local-filevault";
  readonly hash_algorithm: "sha256";
  readonly event_canonicalization: "rfc8785";
  readonly [extension: `x_${string}`]: unknown;
}

const schemaUrl = new URL(
  "../../schemas/v1/vault.schema.json",
  import.meta.url,
);
const vaultSchema = JSON.parse(readFileSync(schemaUrl, "utf8")) as object;

const ajv = createProtocolAjv();
const validateVaultSchema = ajv.compile<VaultManifest>(vaultSchema);

export function validateVaultYaml(
  sourceText: string,
  source = "<memory>",
): VaultManifest {
  const parsed = parseYamlSubset(sourceText, source);

  if (!validateVaultSchema(parsed)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateVaultSchema.errors ?? []),
    );
  }

  return parsed as VaultManifest;
}

export async function readVaultManifest(
  filePath: string,
): Promise<VaultManifest> {
  const bytes = await readFile(filePath);
  const sourceText = decodeYamlBytes(bytes, filePath);
  return validateVaultYaml(sourceText, filePath);
}
