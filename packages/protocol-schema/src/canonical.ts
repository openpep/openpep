// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { createHash } from "node:crypto";
import canonicalize from "canonicalize";
import { validationError } from "./errors.js";

export type JsonPrimitive = null | boolean | number | string;
export type JsonValue =
  | JsonPrimitive
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

export interface CanonicalJson {
  readonly text: string;
  readonly bytes: Uint8Array;
}

export interface EventHashResult extends CanonicalJson {
  readonly eventHash: string;
}

const lowercaseSha256Pattern = /^[0-9a-f]{64}$/;
const textEncoder = new TextEncoder();

export function canonicalizeJson(
  value: unknown,
  source = "<json>",
): CanonicalJson {
  validateIJson(value, source, "/", new Set<object>());

  const text = canonicalize(value);
  if (text === undefined) {
    throw validationError(
      source,
      "/",
      "jcs.unsupported_value",
      "o valor não possui representação JSON canônica",
    );
  }

  return { text, bytes: textEncoder.encode(text) };
}

export function calculateClinicalEventHash(
  event: object,
  source = "<clinical-event>",
): EventHashResult {
  if (Object.hasOwn(event, "event_hash") || Object.hasOwn(event, "signature")) {
    throw validationError(
      source,
      "/",
      "ledger.proof_fields_present",
      "event_hash e signature devem ser removidos antes do cálculo",
    );
  }

  const canonical = canonicalizeJson(event, source);
  const previousEventHash = Object.getOwnPropertyDescriptor(
    event,
    "previous_event_hash",
  )?.value;
  if (typeof previousEventHash !== "string" ||
      !lowercaseSha256Pattern.test(previousEventHash)) {
    throw validationError(
      source,
      "/previous_event_hash",
      "ledger.previous_event_hash",
      "previous_event_hash deve conter SHA-256 hexadecimal minúsculo",
    );
  }

  const eventHash = createHash("sha256")
    .update(Buffer.from(previousEventHash, "hex"))
    .update(canonical.bytes)
    .digest("hex");

  return { ...canonical, eventHash };
}

export function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function validateIJson(
  value: unknown,
  source: string,
  path: string,
  ancestors: Set<object>,
): asserts value is JsonValue {
  if (value === null || typeof value === "boolean") {
    return;
  }

  if (typeof value === "string") {
    if (hasLoneSurrogate(value)) {
      throw validationError(
        source,
        path,
        "jcs.lone_surrogate",
        "strings I-JSON não podem conter surrogate isolado",
      );
    }
    return;
  }

  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw validationError(
        source,
        path,
        "jcs.non_finite_number",
        "números I-JSON devem ser finitos",
      );
    }
    return;
  }

  if (typeof value !== "object") {
    throw validationError(
      source,
      path,
      "jcs.unsupported_value",
      "o valor não pertence ao subconjunto I-JSON",
    );
  }

  if (ancestors.has(value)) {
    throw validationError(
      source,
      path,
      "jcs.circular_reference",
      "referências circulares não são permitidas",
    );
  }

  const prototype = Object.getPrototypeOf(value) as object | null;
  if (!Array.isArray(value) && prototype !== Object.prototype &&
      prototype !== null) {
    throw validationError(
      source,
      path,
      "jcs.object_prototype",
      "somente objetos JSON simples são permitidos",
    );
  }

  ancestors.add(value);
  if (Array.isArray(value)) {
    for (const key of Reflect.ownKeys(value)) {
      if (key === "length") {
        continue;
      }
      if (typeof key !== "string" || !isArrayIndex(key, value.length)) {
        throw validationError(
          source,
          path,
          "jcs.array_property",
          "arrays I-JSON não podem conter propriedades adicionais",
        );
      }
    }

    for (let index = 0; index < value.length; index += 1) {
      const itemPath = appendPath(path, String(index));
      const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
      if (descriptor === undefined) {
        throw validationError(
          source,
          itemPath,
          "jcs.sparse_array",
          "arrays I-JSON não podem conter posições vazias",
        );
      }
      const item = readDataProperty(descriptor, source, itemPath);
      validateIJson(item, source, itemPath, ancestors);
    }
  } else {
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== "string") {
        throw validationError(
          source,
          path,
          "jcs.property_key",
          "objetos I-JSON aceitam somente nomes de propriedade textuais",
        );
      }
      if (hasLoneSurrogate(key)) {
        throw validationError(
          source,
          appendPath(path, key),
          "jcs.lone_surrogate",
          "nomes de propriedade não podem conter surrogate isolado",
        );
      }
      const itemPath = appendPath(path, key);
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (descriptor === undefined) {
        throw validationError(
          source,
          itemPath,
          "jcs.property_descriptor",
          "a propriedade JSON não pôde ser lida com segurança",
        );
      }
      const item = readDataProperty(descriptor, source, itemPath);
      validateIJson(
        item,
        source,
        itemPath,
        ancestors,
      );
    }
  }
  ancestors.delete(value);
}

function readDataProperty(
  descriptor: PropertyDescriptor,
  source: string,
  path: string,
): unknown {
  if (!descriptor.enumerable || !("value" in descriptor)) {
    throw validationError(
      source,
      path,
      "jcs.property_descriptor",
      "propriedades JSON devem ser enumeráveis e não podem executar getters",
    );
  }
  return descriptor.value as unknown;
}

function isArrayIndex(key: string, length: number): boolean {
  if (!/^(?:0|[1-9][0-9]*)$/.test(key)) {
    return false;
  }
  const index = Number(key);
  return Number.isSafeInteger(index) && index >= 0 && index < length &&
    String(index) === key;
}

function hasLoneSurrogate(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (index + 1 >= value.length || next < 0xdc00 || next > 0xdfff) {
        return true;
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return true;
    }
  }
  return false;
}

function appendPath(path: string, part: string): string {
  const escaped = part.replaceAll("~", "~0").replaceAll("/", "~1");
  return path === "/" ? `/${escaped}` : `${path}/${escaped}`;
}
