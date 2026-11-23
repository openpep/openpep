// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import {
  isAlias,
  isMap,
  isScalar,
  isSeq,
  LineCounter,
  parseDocument,
  type Node,
} from "yaml";
import {
  ProtocolValidationError,
  type ProtocolValidationIssue,
  validationError,
} from "./errors.js";

export const maximumYamlBytes = 256 * 1024;
export const maximumYamlDepth = 12;

const yamlKeyPattern = /^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export type YamlValue =
  | null
  | boolean
  | number
  | string
  | readonly YamlValue[]
  | { readonly [key: string]: YamlValue };

export function decodeYamlBytes(
  bytes: Uint8Array,
  source = "<memory>",
): string {
  if (bytes.byteLength > maximumYamlBytes) {
    throw validationError(
      source,
      "/",
      "yaml.maximum_size",
      `o YAML excede ${maximumYamlBytes} bytes`,
    );
  }

  if (
    bytes.byteLength >= 3 &&
    bytes[0] === 0xef &&
    bytes[1] === 0xbb &&
    bytes[2] === 0xbf
  ) {
    throw validationError(
      source,
      "/",
      "yaml.bom",
      "UTF-8 BOM não é permitido",
    );
  }

  try {
    return utf8Decoder.decode(bytes);
  } catch {
    throw validationError(
      source,
      "/",
      "yaml.utf8",
      "o arquivo não contém UTF-8 válido",
    );
  }
}

export function parseYamlSubset(
  sourceText: string,
  source = "<memory>",
): YamlValue {
  validateTextEncodingRules(sourceText, source);

  const lineCounter = new LineCounter();
  const document = parseDocument(sourceText, {
    customTags: [],
    lineCounter,
    merge: false,
    prettyErrors: false,
    resolveKnownTags: false,
    schema: "core",
    strict: true,
    stringKeys: true,
    uniqueKeys: true,
    version: "1.2",
  });

  const parseError = document.errors[0];
  if (parseError !== undefined) {
    const position = lineCounter.linePos(parseError.pos[0]);
    throw validationError(
      source,
      `line:${position.line}:column:${position.col}`,
      `yaml.syntax.${parseError.code.toLowerCase()}`,
      `YAML inválido: ${describeParseError(parseError.code)}`,
    );
  }

  const syntaxIssues = inspectSyntaxNodes(document.contents, source);
  const firstSyntaxIssue =
    syntaxIssues.find((issue) => issue.rule === "yaml.alias") ??
    syntaxIssues.find((issue) => issue.rule === "yaml.anchor") ??
    syntaxIssues.find((issue) => issue.rule === "yaml.tag");

  if (firstSyntaxIssue !== undefined) {
    throw new ProtocolValidationError([firstSyntaxIssue]);
  }

  const parsed = document.toJS({ mapAsMap: true, maxAliasCount: 0 });
  return normalizeValue(parsed, source, "/", 1);
}

function inspectSyntaxNodes(
  root: Node | null,
  source: string,
): ProtocolValidationIssue[] {
  const issues: ProtocolValidationIssue[] = [];

  function inspect(node: Node | null, path: string): void {
    if (node === null) {
      return;
    }

    if (isAlias(node)) {
      issues.push({
        source,
        path,
        rule: "yaml.alias",
        message: "aliases YAML não são permitidos",
      });
      return;
    }

    if ("anchor" in node && typeof node.anchor === "string") {
      issues.push({
        source,
        path,
        rule: "yaml.anchor",
        message: "anchors YAML não são permitidos",
      });
    }
    if ("tag" in node && typeof node.tag === "string") {
      issues.push({
        source,
        path,
        rule: "yaml.tag",
        message: "tags YAML explícitas não são permitidas",
      });
    }

    if (isMap(node)) {
      for (const [index, pair] of node.items.entries()) {
        const key = isScalar(pair.key) && typeof pair.key.value === "string"
          ? pair.key.value
          : `<key:${index}>`;
        const itemPath = appendPath(path, key);
        if (isScalar(pair.key) || isMap(pair.key) || isSeq(pair.key) ||
            isAlias(pair.key)) {
          inspect(pair.key, itemPath);
        }
        if (pair.value !== null &&
            (isScalar(pair.value) || isMap(pair.value) || isSeq(pair.value) ||
             isAlias(pair.value))) {
          inspect(pair.value, itemPath);
        }
      }
    } else if (isSeq(node)) {
      for (const [index, item] of node.items.entries()) {
        if (item !== null &&
            (isScalar(item) || isMap(item) || isSeq(item) || isAlias(item))) {
          inspect(item, appendPath(path, String(index)));
        }
      }
    }
  }

  inspect(root, "/");
  return issues;
}

function validateTextEncodingRules(sourceText: string, source: string): void {
  const byteLength = Buffer.byteLength(sourceText, "utf8");
  if (byteLength > maximumYamlBytes) {
    throw validationError(
      source,
      "/",
      "yaml.maximum_size",
      `o YAML excede ${maximumYamlBytes} bytes`,
    );
  }
  if (sourceText.startsWith("\uFEFF")) {
    throw validationError(
      source,
      "/",
      "yaml.bom",
      "UTF-8 BOM não é permitido",
    );
  }
  if (sourceText.includes("\r")) {
    throw validationError(
      source,
      "/",
      "yaml.line_endings",
      "somente quebras de linha LF são permitidas",
    );
  }
  if (sourceText.normalize("NFC") !== sourceText) {
    throw validationError(
      source,
      "/",
      "yaml.unicode_nfc",
      "o texto deve estar normalizado em Unicode NFC",
    );
  }
}

function normalizeValue(
  value: unknown,
  source: string,
  path: string,
  depth: number,
): YamlValue {
  const isCollection = Array.isArray(value) || value instanceof Map;
  if (isCollection && depth > maximumYamlDepth) {
    throw validationError(
      source,
      path,
      "yaml.maximum_depth",
      `a profundidade máxima é ${maximumYamlDepth}`,
    );
  }

  if (value === null || typeof value === "string" ||
      typeof value === "boolean") {
    return value;
  }

  if (typeof value === "number") {
    if (!Number.isInteger(value)) {
      throw validationError(
        source,
        path,
        "yaml.float",
        "números de ponto flutuante não são permitidos",
      );
    }
    return value;
  }

  if (Array.isArray(value)) {
    return value.map((item, index) =>
      normalizeValue(item, source, appendPath(path, String(index)), depth + 1),
    );
  }

  if (value instanceof Map) {
    const normalized: Record<string, YamlValue> = Object.create(null) as
      Record<string, YamlValue>;

    for (const [key, item] of value.entries()) {
      if (typeof key !== "string") {
        throw validationError(
          source,
          path,
          "yaml.string_key",
          "todas as chaves YAML devem ser strings",
        );
      }
      if (key === "<<") {
        throw validationError(
          source,
          appendPath(path, key),
          "yaml.merge_key",
          "merge keys YAML não são permitidas",
        );
      }
      if (!yamlKeyPattern.test(key)) {
        throw validationError(
          source,
          appendPath(path, key),
          "yaml.key_format",
          "chaves devem usar ASCII snake_case",
        );
      }

      const itemPath = appendPath(path, key);
      normalized[key] = normalizeValue(item, source, itemPath, depth + 1);
    }

    return normalized;
  }

  throw validationError(
    source,
    path,
    "yaml.value_type",
    "o YAML contém um tipo de valor não permitido",
  );
}

function appendPath(path: string, part: string): string {
  const escaped = part.replaceAll("~", "~0").replaceAll("/", "~1");
  return path === "/" ? `/${escaped}` : `${path}/${escaped}`;
}

function describeParseError(code: string): string {
  switch (code) {
    case "DUPLICATE_KEY":
      return "chave duplicada";
    case "MULTIPLE_DOCS":
      return "mais de um documento";
    case "NON_STRING_KEY":
      return "chave não textual";
    case "TAG_RESOLVE_FAILED":
      return "tag não reconhecida";
    default:
      return `erro de sintaxe ${code}`;
  }
}

export function isProtocolValidationError(
  error: unknown,
): error is ProtocolValidationError {
  return error instanceof ProtocolValidationError;
}
