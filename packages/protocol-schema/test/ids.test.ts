// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";
import {
  isOpenPepId,
  isUuidV7,
  openPepIdPrefixes,
  parseOpenPepId,
} from "../src/ids.js";

const uuidV7 = "0198f5c0-7f36-7b65-9f31-11a0d536a21f";

test("accepts every protocol prefix with a lowercase UUIDv7", () => {
  for (const [type, prefix] of Object.entries(openPepIdPrefixes)) {
    const id = `${prefix}_${uuidV7}`;
    assert.equal(isOpenPepId(id), true);
    assert.deepEqual(parseOpenPepId(id), { type, uuid: uuidV7 });
  }
});

test("checks the expected entity type", () => {
  assert.equal(isOpenPepId(`vlt_${uuidV7}`, "vault"), true);
  assert.equal(isOpenPepId(`vlt_${uuidV7}`, "device"), false);
});

test("rejects UUID versions other than v7", () => {
  const uuidV4 = "550e8400-e29b-41d4-a716-446655440000";
  assert.equal(isUuidV7(uuidV4), false);
  assert.equal(isOpenPepId(`vlt_${uuidV4}`), false);
});

test("rejects uppercase, unknown prefixes and malformed variants", () => {
  assert.equal(isOpenPepId(`VLT_${uuidV7}`), false);
  assert.equal(isOpenPepId(`person_${uuidV7}`), false);
  assert.equal(
    isOpenPepId("vlt_0198f5c0-7f36-7b65-7f31-11a0d536a21f"),
    false,
  );
});
