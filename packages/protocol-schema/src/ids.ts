// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

export const openPepIdPrefixes = {
  vault: "vlt",
  patient: "pt",
  encounter: "enc",
  note: "note",
  asset: "asset",
  appointment: "appt",
  action: "act",
  event: "evt",
  user: "usr",
  device: "dev",
  signingKey: "key",
} as const;

export type OpenPepIdType = keyof typeof openPepIdPrefixes;

export interface ParsedOpenPepId {
  readonly type: OpenPepIdType;
  readonly uuid: string;
}

const uuidV7Pattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const prefixToType = new Map<string, OpenPepIdType>(
  Object.entries(openPepIdPrefixes).map(([type, prefix]) => [
    prefix,
    type as OpenPepIdType,
  ]),
);

export function isUuidV7(value: string): boolean {
  return uuidV7Pattern.test(value);
}

export function parseOpenPepId(value: string): ParsedOpenPepId | null {
  const separator = value.indexOf("_");
  if (separator < 1) {
    return null;
  }

  const prefix = value.slice(0, separator);
  const uuid = value.slice(separator + 1);
  const type = prefixToType.get(prefix);

  if (type === undefined || !isUuidV7(uuid)) {
    return null;
  }

  return { type, uuid };
}

export function isOpenPepId(
  value: string,
  expectedType?: OpenPepIdType,
): boolean {
  const parsed = parseOpenPepId(value);
  return parsed !== null &&
    (expectedType === undefined || parsed.type === expectedType);
}
