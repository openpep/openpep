// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  bindAppointmentManifestToFile,
  ProtocolValidationError,
  readAppointmentManifest,
  validateAppointmentYaml,
} from "../src/index.js";

const fixtureRoot = fileURLToPath(new URL(
  "../../../../fixtures/appointment-v1/",
  import.meta.url,
));

test("accepts in-person and telemedicine appointments", async () => {
  const inPerson = await readAppointmentManifest(
    join(fixtureRoot, "valid/in-person/appointment.yaml"),
  );
  const telemedicine = await readAppointmentManifest(
    join(fixtureRoot, "valid/telemedicine/appointment.yaml"),
  );
  assert.equal(inPerson.modality, "in_person");
  assert.equal(telemedicine.remote_access_url, "https://facetime.apple.com/join/synthetic-room");
  assert.equal(telemedicine.x_fixture_note, "preserved");
});

test("rejects every persisted invalid appointment", async () => {
  const invalidRoot = join(fixtureRoot, "invalid");
  const cases = await readdir(invalidRoot, { withFileTypes: true });
  for (const fixtureCase of cases) {
    if (!fixtureCase.isDirectory()) continue;
    const manifestPath = join(invalidRoot, fixtureCase.name, "appointment.yaml");
    const expectation = JSON.parse(await readFile(
      join(dirname(manifestPath), "expectation.json"),
      "utf8",
    )) as { rule: string; path: string };
    await assert.rejects(readAppointmentManifest(manifestPath), (error) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, expectation.rule);
      assert.equal(error.issues[0]?.path, expectation.path);
      return true;
    });
  }
});

test("binds appointment_id to the file name", async () => {
  const appointment = await readAppointmentManifest(
    join(fixtureRoot, "valid/in-person/appointment.yaml"),
  );
  assert.equal(
    bindAppointmentManifestToFile(
      appointment,
      `${appointment.appointment_id}.yaml`,
    ),
    appointment,
  );
  assert.throws(
    () => bindAppointmentManifestToFile(
      appointment,
      "appt_0198f6c0-0000-7000-8000-000000000099.yaml",
    ),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "appointment.appointment_id_mismatch");
      return true;
    },
  );
});

test("accepts an opaque encounter link", async () => {
  const source = await readFile(
    join(fixtureRoot, "valid/in-person/appointment.yaml"),
    "utf8",
  );
  const linked = validateAppointmentYaml(source.replace(
    "encounter_id: null",
    "encounter_id: enc_0198f5d1-0000-7000-8000-000000000001",
  ));
  assert.equal(
    linked.encounter_id,
    "enc_0198f5d1-0000-7000-8000-000000000001",
  );
  assert.throws(
    () => validateAppointmentYaml(source.replace(
      "encounter_id: null",
      "encounter_id: enc_not-safe",
    )),
    ProtocolValidationError,
  );
});
