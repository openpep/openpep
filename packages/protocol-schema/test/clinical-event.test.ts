// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { validateClinicalEvent } from "../src/clinical-event.js";
import { ProtocolValidationError } from "../src/errors.js";

const goldenLedger = fileURLToPath(
  new URL(
    "../../../../fixtures/clinical-ledger-v1/golden/two-events/ledger.ndjson",
    import.meta.url,
  ),
);

test("validates a stored clinical event", async () => {
  const firstLine = (await readFile(goldenLedger, "utf8")).split("\n")[0];
  const event = validateClinicalEvent(JSON.parse(firstLine ?? ""));
  assert.equal(event.schema, "openpep/clinical-event@1");
  assert.equal(event.sequence, 1);
  assert.match(event.event_hash, /^[0-9a-f]{64}$/);
});

test("reports required event fields at their JSON Pointer", async () => {
  const event = await readFirstEvent();
  delete event.event_hash;
  assertIssue(event, "schema.required", "/event_hash");

  const withoutKey = await readFirstEvent();
  delete withoutKey.signing_key_id;
  assertIssue(withoutKey, "schema.required", "/signing_key_id");
});

test("rejects unsafe paths, invalid timestamps and unknown fields", async () => {
  const unsafePath = await readFirstEvent();
  unsafePath.relative_path = "content/../patient.md";
  assertIssue(unsafePath, "schema.pattern", "/relative_path");

  const offsetTimestamp = await readFirstEvent();
  offsetTimestamp.occurred_at = "2026-08-30T14:40:00-03:00";
  assertIssue(offsetTimestamp, "schema.format", "/occurred_at");

  const unknown = await readFirstEvent();
  unknown.doctor_name = "Synthetic";
  assertIssue(unknown, "schema.additionalProperties", "/doctor_name");
});

test("allows namespaced extensions and reserves base64url signature syntax", async () => {
  const extended = await readFirstEvent();
  extended.x_test_profile = { source: "synthetic" };
  const event = validateClinicalEvent(extended);
  assert.deepEqual(event.x_test_profile, { source: "synthetic" });

  extended.signature = "not+base64url";
  assertIssue(extended, "schema.pattern", "/signature");
});

test("rejects accessors without executing them", async () => {
  const event = await readFirstEvent();
  let executed = false;
  Object.defineProperty(event, "event_hash", {
    enumerable: true,
    get() {
      executed = true;
      return "0".repeat(64);
    },
  });

  assert.throws(() => validateClinicalEvent(event), (error: unknown) => {
    assert.ok(error instanceof ProtocolValidationError);
    assert.equal(error.issues[0]?.rule, "jcs.property_descriptor");
    assert.equal(error.issues[0]?.path, "/event_hash");
    return true;
  });
  assert.equal(executed, false);
});

async function readFirstEvent(): Promise<Record<string, unknown>> {
  const firstLine = (await readFile(goldenLedger, "utf8")).split("\n")[0];
  return JSON.parse(firstLine ?? "") as Record<string, unknown>;
}

function assertIssue(
  value: unknown,
  expectedRule: string,
  expectedPath: string,
): void {
  assert.throws(() => validateClinicalEvent(value, "event.json"), (error) => {
    assert.ok(error instanceof ProtocolValidationError);
    assert.ok(
      error.issues.some((issue) =>
        issue.rule === expectedRule && issue.path === expectedPath
      ),
    );
    return true;
  });
}
