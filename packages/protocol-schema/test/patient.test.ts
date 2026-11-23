// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  bindPatientManifestToDirectory,
  ProtocolValidationError,
  readPatientManifest,
  validatePatientYaml,
} from "../src/index.js";

const fixtureRoot = fileURLToPath(new URL(
  "../../../../fixtures/patient-v1/",
  import.meta.url,
));

test("accepts unnamed, minimal, and complete patient manifests", async () => {
  const unnamed = await readPatientManifest(
    join(fixtureRoot, "valid/unnamed/patient.yaml"),
  );
  const minimal = await readPatientManifest(
    join(fixtureRoot, "valid/minimal/patient.yaml"),
  );
  const complete = await readPatientManifest(
    join(fixtureRoot, "valid/complete/patient.yaml"),
  );
  assert.equal(unnamed.full_name, null);
  assert.equal(minimal.full_name, "Ana Fictícia");
  assert.equal(complete.preferred_name, "Joca");
  assert.equal(complete.contacts.length, 2);
  assert.equal(complete.x_fixture_note, "preserved");
});

test("rejects every persisted invalid patient manifest", async () => {
  const invalidRoot = join(fixtureRoot, "invalid");
  const cases = await readdir(invalidRoot, { withFileTypes: true });
  for (const fixtureCase of cases) {
    if (!fixtureCase.isDirectory()) continue;
    const manifestPath = join(invalidRoot, fixtureCase.name, "patient.yaml");
    const expectation = JSON.parse(await readFile(
      join(dirname(manifestPath), "expectation.json"),
      "utf8",
    )) as { rule: string; path: string };
    await assert.rejects(readPatientManifest(manifestPath), (error) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, expectation.rule);
      assert.equal(error.issues[0]?.path, expectation.path);
      return true;
    });
  }
});

test("binds patient_id to the opaque directory", async () => {
  const patient = await readPatientManifest(
    join(fixtureRoot, "valid/minimal/patient.yaml"),
  );
  assert.equal(
    bindPatientManifestToDirectory(patient, patient.patient_id),
    patient,
  );
  assert.throws(
    () => bindPatientManifestToDirectory(
      patient,
      "pt_0198f5c2-0000-7000-8000-000000000099",
    ),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "patient.patient_id_mismatch");
      return true;
    },
  );
});

test("rejects impossible dates and incoherent timestamps", () => {
  const base = `schema: openpep/patient@1\n` +
    `patient_id: pt_0198f5c2-0000-7000-8000-000000000001\n` +
    `status: active\nfull_name: Synthetic\npreferred_name: null\n` +
    `birth_date: "2025-02-29"\ncontacts: []\nidentifiers: []\nalerts: []\n` +
    `created_at: "2026-08-31T18:00:00Z"\n` +
    `updated_at: "2026-08-31T17:00:00Z"\narchived_at: null\n`;
  assert.throws(() => validatePatientYaml(base), ProtocolValidationError);
  const validDate = base.replace("2025-02-29", "2024-02-29");
  assert.throws(
    () => validatePatientYaml(validDate),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "patient.updated_before_created");
      return true;
    },
  );
});
