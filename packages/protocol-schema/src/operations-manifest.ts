// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { ProtocolValidationError, validationError } from "./errors.js";
import { createProtocolAjv, schemaIssues } from "./schema-validation.js";
import type { VaultManifest } from "./validate.js";
import { decodeYamlBytes, parseYamlSubset, readYamlFileBytes } from "./yaml.js";

export interface OperationsManifest {
  readonly schema: "openpep/operations-manifest@1";
  readonly vault_id: string;
  readonly state: "empty";
  readonly [extension: `x_${string}`]: unknown;
}

const schemaUrl = new URL(
  "../../schemas/v1/operations-manifest.schema.json",
  import.meta.url,
);
const operationsSchema = JSON.parse(readFileSync(schemaUrl, "utf8")) as object;
const ajv = createProtocolAjv();
const validateSchema = ajv.compile<OperationsManifest>(operationsSchema);

export function validateOperationsManifestYaml(
  sourceText: string,
  source = "<memory>",
): OperationsManifest {
  const parsed = parseYamlSubset(sourceText, source);
  if (!validateSchema(parsed)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateSchema.errors ?? []),
    );
  }
  return parsed as OperationsManifest;
}

export async function readOperationsManifest(
  filePath: string,
): Promise<OperationsManifest> {
  const bytes = await readYamlFileBytes(filePath);
  const sourceText = decodeYamlBytes(bytes, filePath);
  return validateOperationsManifestYaml(sourceText, filePath);
}

export function bindOperationsManifestToVault(
  operations: OperationsManifest,
  vault: VaultManifest,
  source = "operations/manifest.yaml",
): OperationsManifest {
  if (operations.vault_id !== vault.vault_id) {
    throw validationError(
      source,
      "/vault_id",
      "operations.vault_id_mismatch",
      "o vault_id deve corresponder ao manifesto da raiz",
    );
  }
  return operations;
}
