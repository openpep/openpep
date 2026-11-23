// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { Ajv2020, type ErrorObject } from "ajv/dist/2020.js";
import type { ProtocolValidationIssue } from "./errors.js";

export function createProtocolAjv(): Ajv2020 {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  ajv.addFormat("date-time", {
    type: "string",
    validate: isUtcRfc3339,
  });
  ajv.addFormat("date", {
    type: "string",
    validate: isCalendarDate,
  });
  return ajv;
}

export function schemaIssues(
  source: string,
  errors: readonly ErrorObject[],
): ProtocolValidationIssue[] {
  return errors.map((error) => ({
    source,
    path: schemaErrorPath(error),
    rule: `schema.${error.keyword}`,
    message: error.message ?? "o valor não atende ao schema",
  }));
}

export function compareUtcRfc3339(left: string, right: string): number {
  const leftParts = rfc3339Parts(left);
  const rightParts = rfc3339Parts(right);
  if (leftParts === null || rightParts === null) {
    throw new TypeError("timestamps must be valid UTC RFC 3339 strings");
  }

  for (let index = 0; index < 6; index += 1) {
    const difference = (leftParts.fields[index] ?? 0) -
      (rightParts.fields[index] ?? 0);
    if (difference !== 0) {
      return Math.sign(difference);
    }
  }

  const fractionLength = Math.max(
    leftParts.fraction.length,
    rightParts.fraction.length,
  );
  const leftFraction = leftParts.fraction.padEnd(fractionLength, "0");
  const rightFraction = rightParts.fraction.padEnd(fractionLength, "0");
  return leftFraction < rightFraction ? -1 : leftFraction > rightFraction ? 1 : 0;
}

function schemaErrorPath(error: ErrorObject): string {
  if (error.keyword === "required") {
    const missingProperty = (error.params as { missingProperty?: unknown })
      .missingProperty;
    if (typeof missingProperty === "string") {
      return appendJsonPointer(error.instancePath, missingProperty);
    }
  }
  if (error.keyword === "additionalProperties") {
    const additionalProperty = (error.params as {
      additionalProperty?: unknown;
    }).additionalProperty;
    if (typeof additionalProperty === "string") {
      return appendJsonPointer(error.instancePath, additionalProperty);
    }
  }
  return error.instancePath === "" ? "/" : error.instancePath;
}

function appendJsonPointer(path: string, part: string): string {
  const escaped = part.replaceAll("~", "~0").replaceAll("/", "~1");
  return path === "" ? `/${escaped}` : `${path}/${escaped}`;
}

function isUtcRfc3339(value: string): boolean {
  const parts = rfc3339Parts(value);
  if (parts === null) {
    return false;
  }

  const [year, month, day, hour, minute, second] = parts.fields;

  if (year === undefined || month === undefined || day === undefined ||
      hour === undefined || minute === undefined || second === undefined ||
      year < 1 || month < 1 || month > 12 || day < 1 || hour > 23 ||
      minute > 59 || second > 59) {
    return false;
  }

  const maximumDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day <= maximumDay;
}

function isCalendarDate(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (match === null) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (year < 1 || month < 1 || month > 12 || day < 1) return false;
  return day <= new Date(Date.UTC(year, month, 0)).getUTCDate();
}

function rfc3339Parts(value: string): {
  readonly fields: readonly number[];
  readonly fraction: string;
} | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$/.exec(
    value,
  );
  if (match === null) {
    return null;
  }
  return {
    fields: match.slice(1, 7).map(Number),
    fraction: match[7] ?? "",
  };
}
