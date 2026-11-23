// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  checkpointExpectation,
  validateClinicalLedgerCheckpoint,
} from "../src/checkpoint.js";
import { ProtocolValidationError } from "../src/errors.js";

const goldenCheckpoint = fileURLToPath(
  new URL(
    "../../../../fixtures/clinical-ledger-v1/golden/two-events/checkpoint.json",
    import.meta.url,
  ),
);

test("validates and maps the golden checkpoint", async () => {
  const checkpoint = validateClinicalLedgerCheckpoint(
    JSON.parse(await readFile(goldenCheckpoint, "utf8")),
    goldenCheckpoint,
  );
  assert.deepEqual(checkpointExpectation(checkpoint), {
    patientId: "pt_0198f5c2-0000-7000-8000-000000000001",
    eventCount: 2,
    headEventHash: "74d0f12aa384b7b91d4d12287b67b58868e87669977309b49f90a294204fc008",
  });
});

test("rejects an incomplete or malformed checkpoint", () => {
  assert.throws(
    () => validateClinicalLedgerCheckpoint({
      schema: "openpep/clinical-ledger-checkpoint@1",
      patient_id: "pt_invalid",
      event_count: -1,
      head_event_hash: "A".repeat(64),
    }),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.ok(error.issues.length >= 3);
      return true;
    },
  );
});
