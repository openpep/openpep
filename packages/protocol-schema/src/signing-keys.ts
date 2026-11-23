// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { canonicalizeJson, type JsonValue } from "./canonical.js";
import { ProtocolValidationError, validationError } from "./errors.js";
import {
  compareUtcRfc3339,
  createProtocolAjv,
  schemaIssues,
} from "./schema-validation.js";
import { validateP256PublicKeyX963 } from "./signatures.js";

export interface ClinicalSigningKey {
  readonly key_id: string;
  readonly device_id: string;
  readonly algorithm: "ES256";
  readonly public_key_x963: string;
  readonly authorized_from: string;
  readonly authorized_until?: string;
  readonly [extension: `x_${string}`]: JsonValue;
}

export interface SigningKeyRegistry {
  readonly schema: "openpep/signing-key-registry@1";
  readonly keys: readonly ClinicalSigningKey[];
  readonly [extension: `x_${string}`]: JsonValue;
}

const schemaUrl = new URL(
  "../../schemas/v1/signing-key-registry.schema.json",
  import.meta.url,
);
const signingKeyRegistrySchema = JSON.parse(
  readFileSync(schemaUrl, "utf8"),
) as object;
const ajv = createProtocolAjv();
const validateSigningKeyRegistrySchema = ajv.compile<SigningKeyRegistry>(
  signingKeyRegistrySchema,
);

export function validateSigningKeyRegistry(
  value: unknown,
  source = "<signing-key-registry>",
): SigningKeyRegistry {
  canonicalizeJson(value, source);
  if (!validateSigningKeyRegistrySchema(value)) {
    throw new ProtocolValidationError(
      schemaIssues(source, validateSigningKeyRegistrySchema.errors ?? []),
    );
  }

  const keyIds = new Set<string>();
  const publicKeys = new Set<string>();
  for (let index = 0; index < value.keys.length; index += 1) {
    const key = value.keys[index];
    if (key === undefined) {
      continue;
    }
    const basePath = `/keys/${index}`;
    if (keyIds.has(key.key_id)) {
      throw validationError(
        source,
        `${basePath}/key_id`,
        "signing_keys.duplicate_key_id",
        "key_id aparece mais de uma vez no registro",
      );
    }
    keyIds.add(key.key_id);
    if (publicKeys.has(key.public_key_x963)) {
      throw validationError(
        source,
        `${basePath}/public_key_x963`,
        "signing_keys.duplicate_public_key",
        "a mesma chave pública não pode possuir mais de um key_id",
      );
    }
    publicKeys.add(key.public_key_x963);

    if (key.authorized_until !== undefined &&
        compareUtcRfc3339(key.authorized_from, key.authorized_until) >= 0) {
      throw validationError(
        source,
        `${basePath}/authorized_until`,
        "signing_keys.authorization_window",
        "authorized_until deve ser posterior a authorized_from",
      );
    }
    validateP256PublicKeyX963(
      key.public_key_x963,
      source,
      `${basePath}/public_key_x963`,
    );
  }
  return value;
}

export function findAuthorizedSigningKey(
  registry: SigningKeyRegistry,
  keyId: string,
  deviceId: string,
  occurredAt: string,
  source = "<clinical-event>",
  path = "/signing_key_id",
): ClinicalSigningKey {
  const key = registry.keys.find((candidate) => candidate.key_id === keyId);
  if (key === undefined) {
    throw validationError(
      source,
      path,
      "ledger.signing_key_missing",
      "a chave de assinatura não existe no registro confiável",
    );
  }
  if (key.device_id !== deviceId) {
    throw validationError(
      source,
      path,
      "ledger.signing_key_device",
      "a chave de assinatura não pertence ao dispositivo do evento",
    );
  }
  if (compareUtcRfc3339(occurredAt, key.authorized_from) < 0 ||
      (key.authorized_until !== undefined &&
        compareUtcRfc3339(occurredAt, key.authorized_until) >= 0)) {
    throw validationError(
      source,
      path,
      "ledger.signing_key_not_authorized",
      "a chave não estava autorizada no instante registrado pelo evento",
    );
  }
  return key;
}
