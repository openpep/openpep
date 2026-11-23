// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  bindProgressiveSummaryWork,
  ProtocolValidationError,
  validateProgressiveSummaryWorkJson,
} from "../src/index.js";

const fixtureRoot = fileURLToPath(new URL(
  "../../../../fixtures/progressive-summary-work-v1/",
  import.meta.url,
));
const fixtureRootV2 = fileURLToPath(new URL(
  "../../../../fixtures/progressive-summary-work-v2/",
  import.meta.url,
));

test("accepts a complete synthetic progressive-summary work document", async () => {
  const document = validateProgressiveSummaryWorkJson(await readFile(
    join(fixtureRoot, "valid/complete/work.json"),
  ));
  assert.equal(document.schema, "openpep/progressive-summary-work@1");
  assert.equal(document.segments.length, 2);
  assert.equal(document.blocks[1]?.acceptance?.source_asset_id,
    "asset_0198f7ad-0000-7000-8000-000000000001");
});

test("accepts one-minute summary blocks for synthetic live tests", async () => {
  const fixture = JSON.parse(await readFile(
    join(fixtureRoot, "valid/complete/work.json"),
    "utf8",
  )) as { summary_interval_seconds: number };
  fixture.summary_interval_seconds = 60;
  const document = validateProgressiveSummaryWorkJson(Buffer.from(JSON.stringify(fixture)));
  assert.equal(document.summary_interval_seconds, 60);
});

test("accepts an incremental summary with an auditable revision", async () => {
  const document = validateProgressiveSummaryWorkJson(await readFile(
    join(fixtureRootV2, "valid/incremental/work.json"),
  ));
  assert.equal(document.schema, "openpep/progressive-summary-work@2");
  assert.equal(document.summary?.revision, 1);
  assert.equal(document.summary?.items[0]?.text, "- Melhora referida.");
});

test("rejects every persisted invalid incremental-summary document", async () => {
  const root = join(fixtureRootV2, "invalid");
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const directory = join(root, entry.name);
    const expectation = JSON.parse(await readFile(join(directory, "expectation.json"), "utf8")) as {
      readonly rule: string;
      readonly path: string;
    };
    assert.throws(
      () => validateProgressiveSummaryWorkJson(readFileSyncBytes(join(directory, "work.json"))),
      (error: unknown) => error instanceof ProtocolValidationError &&
        error.issues[0]?.rule === expectation.rule && error.issues[0]?.path === expectation.path,
    );
  }
});

test("rejects every persisted invalid progressive-summary work document", async () => {
  const root = join(fixtureRoot, "invalid");
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const directory = join(root, entry.name);
    const expectation = JSON.parse(await readFile(join(directory, "expectation.json"), "utf8")) as {
      readonly rule: string;
      readonly path: string;
    };
    assert.throws(
      () => validateProgressiveSummaryWorkJson(readFileSyncBytes(join(directory, "work.json"))),
      (error: unknown) => error instanceof ProtocolValidationError &&
        error.issues[0]?.rule === expectation.rule && error.issues[0]?.path === expectation.path,
    );
  }
});

test("binds the work document to the intended vault, patient and encounter", async () => {
  const document = validateProgressiveSummaryWorkJson(await readFile(
    join(fixtureRoot, "valid/complete/work.json"),
  ));
  assert.equal(bindProgressiveSummaryWork(document, {
    vault_id: document.vault_id,
    patient_id: document.patient_id,
    encounter_id: document.encounter_id,
  }), document);
  assert.throws(
    () => bindProgressiveSummaryWork(document, { ...document, encounter_id: "enc_0198f7a3-0000-7000-8000-000000000002" }),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "progressive_summary_work.binding_mismatch" &&
      error.issues[0]?.path === "/encounter_id",
  );
});

test("requires every transcript segment to belong to the capture attempt", async () => {
  const fixture = JSON.parse(await readFile(
    join(fixtureRoot, "valid/complete/work.json"),
    "utf8",
  )) as { segments: Array<{ attempt_id: string }> };
  fixture.segments[0]!.attempt_id = "attempt_0198f7ae-0000-7000-8000-000000000001";
  assert.throws(
    () => validateProgressiveSummaryWorkJson(Buffer.from(JSON.stringify(fixture))),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "progressive_summary_work.segment_attempt_mismatch" &&
      error.issues[0]?.path === "/segments/0/attempt_id",
  );
});

function readFileSyncBytes(path: string): Uint8Array {
  // The persisted cases are intentionally parsed synchronously inside assert.throws.
  return new Uint8Array(readFileSync(path));
}


test("accepts resumed capture while retaining compatibility with one-file captures", async () => {
  const resumed = validateProgressiveSummaryWorkJson(await readFile(join(fixtureRootV2, "valid/resumed/work.json")));
  assert.deepEqual(resumed.capture.audio_filenames, ["consulta-parte-1.wav", "consulta-parte-2.wav"]);
  const original = validateProgressiveSummaryWorkJson(await readFile(join(fixtureRootV2, "valid/incremental/work.json")));
  assert.equal(original.capture.audio_filenames, undefined);
  for (const filenames of [["../escape.wav"], ["consulta-parte-2.wav", "consulta-parte-2.wav"], []]) {
    const changed = { ...resumed, capture: { ...resumed.capture, audio_filenames: filenames } };
    assert.throws(() => validateProgressiveSummaryWorkJson(Buffer.from(JSON.stringify(changed))), ProtocolValidationError);
  }
});
