// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import {
  cp,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { inspectVaultDirectory, readVaultManifest } from "../src/index.js";

const repositoryRoot = new URL("../../../../", import.meta.url);
const emptyVault = new URL("fixtures/vault-v1/valid/empty-vault/", repositoryRoot);
const scopedFixture = new URL(
  "fixtures/vault-directory-v1/scoped-isolation/",
  repositoryRoot,
);

test("isolates one invalid patient and preserves unmanaged root content", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-directory-"));
  try {
    const source = await materializeScopedFixture(temporary);
    const unmanagedPath = join(source, "notes-for-user.txt");
    const unmanagedBefore = await readFile(unmanagedPath);
    const manifestBefore = await readFile(join(source, "vault.yaml"));
    const result = await inspectVaultDirectory(source);

    assert.equal(result.ok, false);
    assert.equal(result.readable, true);
    assert.equal(result.writing_allowed, true);
    assert.deepEqual(result.valid_patients, [
      "pt_0198f5c2-0000-7000-8000-000000000001",
      "pt_0198f5c2-0000-7000-8000-000000000002",
    ]);
    assert.deepEqual(result.unavailable_patients, [
      "pt_0198f5c2-0000-7000-8000-000000000003",
    ]);
    assert.deepEqual(result.unmanaged_paths, ["notes-for-user.txt"]);
    assert.ok(result.items.some((item) =>
      item.rule === "patient.required_directory" &&
      item.patient_id === "pt_0198f5c2-0000-7000-8000-000000000003"
    ));
    assert.deepEqual(await readFile(unmanagedPath), unmanagedBefore);
    assert.deepEqual(await readFile(join(source, "vault.yaml")), manifestBefore);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test(
  "does not inspect derived wiki contents when validating a patient",
  { skip: process.platform === "win32" },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-wiki-isolation-"));
    try {
      const source = await materializeScopedFixture(temporary);
      const patientID = "pt_0198f5c2-0000-7000-8000-000000000001";
      const wiki = join(source, "patients", patientID, "wiki");
      const outside = join(temporary, "outside-wiki.md");
      await writeFile(join(wiki, "summary.md"), Buffer.from([0xff, 0x00, 0xfe]));
      await mkdir(join(wiki, "unknown", "nested"), { recursive: true });
      await writeFile(join(wiki, "unknown", "nested", "future.bin"), "future bytes");
      await writeFile(outside, "must not be followed\n");
      await symlink(outside, join(wiki, "future-link"));

      const result = await inspectVaultDirectory(source);
      assert.equal(result.writing_allowed, true);
      assert.ok(result.valid_patients.includes(patientID));
      assert.ok(!result.unavailable_patients.includes(patientID));
      assert.deepEqual(await readFile(outside, "utf8"), "must not be followed\n");
      assert.ok(!result.items.some((entry) => entry.path.includes("/wiki/")));
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test("keeps v1 extensions and treats indexes as disposable", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-indexes-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const manifestPath = join(source, "vault.yaml");
    const original = await readFile(manifestPath, "utf8");
    const extended = `${original}x_fixture_note: preserved\n`;
    await writeFile(manifestPath, extended);
    await rm(join(source, "indexes"), { recursive: true });

    const result = await inspectVaultDirectory(source);
    assert.equal(result.ok, true);
    assert.equal(result.protocol_version, "1.0");
    assert.equal(result.writing_allowed, true);
    const manifest = await readVaultManifest(manifestPath);
    assert.equal(manifest.x_fixture_note, "preserved");
    assert.equal(await readFile(manifestPath, "utf8"), extended);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("recognizes prescribing registries and isolates an invalid one", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-prescribing-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const vaultID = (await inspectVaultDirectory(source)).vault_id;
    const registry = {
      format: "openpep-sncr-registry-v1",
      vaultID,
      requests: [],
      numbers: [],
    };
    const homologation = join(source, "prescribing-homologation.json");
    const production = join(source, "prescribing-production.json");
    await writeFile(homologation, JSON.stringify(registry));
    await writeFile(
      production,
      JSON.stringify({ ...registry, environment: "production" }),
    );

    const valid = await inspectVaultDirectory(source);
    assert.equal(valid.ok, true);
    assert.deepEqual(valid.unmanaged_paths, []);
    assert.equal(
      valid.items.filter((candidate) =>
        candidate.rule === "prescribing.registry_valid"
      ).length,
      2,
    );

    // Homologation numbers under the production name must never be accepted.
    await writeFile(production, JSON.stringify(registry));
    const mixed = await inspectVaultDirectory(source);
    assert.equal(mixed.ok, false);
    assert.equal(mixed.readable, true);
    assert.equal(mixed.writing_allowed, true);
    assert.deepEqual(
      mixed.items
        .filter((candidate) => candidate.status === "invalid")
        .map((candidate) => [candidate.scope, candidate.path, candidate.rule]),
      [["artifact", "prescribing-production.json", "prescribing.registry_invalid"]],
    );
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("accepts inert recovery content and rejects recovery as a regular file", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-recovery-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const recovery = join(source, "recovery");
    await mkdir(recovery);
    await writeFile(join(recovery, "encounter-synthetic.md"), "synthetic recovery bytes\n");

    const valid = await inspectVaultDirectory(source);
    assert.equal(valid.ok, true);
    assert.equal(valid.writing_allowed, true);
    assert.deepEqual(valid.unmanaged_paths, []);

    await rm(recovery, { recursive: true });
    await writeFile(recovery, "synthetic invalid root entry\n");
    const blocked = await inspectVaultDirectory(source);
    assert.equal(blocked.readable, false);
    assert.equal(blocked.writing_allowed, false);
    assert.ok(blocked.items.some((item) =>
      item.path === "recovery" && item.rule === "filesystem.directory"
    ));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("accepts inert recordings content and rejects recordings as a regular file", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-recordings-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const recordings = join(source, "recordings");
    await mkdir(recordings);
    await writeFile(join(recordings, "encounter-synthetic.md"), "synthetic recordings bytes\n");

    const valid = await inspectVaultDirectory(source);
    assert.equal(valid.ok, true);
    assert.equal(valid.writing_allowed, true);
    assert.deepEqual(valid.unmanaged_paths, []);

    await rm(recordings, { recursive: true });
    await writeFile(recordings, "synthetic invalid root entry\n");
    const blocked = await inspectVaultDirectory(source);
    assert.equal(blocked.readable, false);
    assert.equal(blocked.writing_allowed, false);
    assert.ok(blocked.items.some((item) =>
      item.path === "recordings" && item.rule === "filesystem.directory"
    ));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test(
  "rejects recovery as a symbolic link",
  { skip: process.platform === "win32" },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-recovery-link-"));
    try {
      const source = await materializeEmptyVault(temporary);
      const outside = join(temporary, "outside-recovery");
      await mkdir(outside);
      await symlink(outside, join(source, "recovery"));

      const blocked = await inspectVaultDirectory(source);
      assert.equal(blocked.readable, false);
      assert.equal(blocked.writing_allowed, false);
      assert.ok(blocked.items.some((item) =>
        item.path === "recovery" && item.rule === "filesystem.symlink"
      ));
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test(
  "rejects recordings as a symbolic link",
  { skip: process.platform === "win32" },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-recordings-link-"));
    try {
      const source = await materializeEmptyVault(temporary);
      const outside = join(temporary, "outside-recordings");
      await mkdir(outside);
      await symlink(outside, join(source, "recordings"));

      const blocked = await inspectVaultDirectory(source);
      assert.equal(blocked.readable, false);
      assert.equal(blocked.writing_allowed, false);
      assert.ok(blocked.items.some((item) =>
        item.path === "recordings" && item.rule === "filesystem.symlink"
      ));
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test("accepts a registered patient and binds patient_id to its directory", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-patient-manifest-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const patientID = "pt_0198f5c2-0000-7000-8000-000000000001";
    await materializePatient(source, patientID);
    await cp(
      new URL("fixtures/patient-v1/valid/minimal/patient.yaml", repositoryRoot),
      join(source, "patients", patientID, "patient.yaml"),
    );
    const valid = await inspectVaultDirectory(source);
    assert.deepEqual(valid.valid_patients, [patientID]);
    assert.ok(valid.items.some((item) => item.rule === "patient.manifest_valid"));

    await writeFile(
      join(source, "patients", patientID, "patient.yaml"),
      (await readFile(join(source, "patients", patientID, "patient.yaml"), "utf8"))
        .replace(patientID, "pt_0198f5c2-0000-7000-8000-000000000099"),
    );
    const mismatched = await inspectVaultDirectory(source);
    assert.deepEqual(mismatched.valid_patients, []);
    assert.deepEqual(mismatched.unavailable_patients, [patientID]);
    assert.ok(mismatched.items.some((item) =>
      item.rule === "patient.patient_id_mismatch" && item.patient_id === patientID
    ));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("validates appointments by path and isolates one invalid item", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-appointments-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const patientID = "pt_0198f5c2-0000-7000-8000-000000000001";
    const validID = "appt_0198f6c0-0000-7000-8000-000000000001";
    const invalidID = "appt_0198f6c0-0000-7000-8000-000000000003";
    await materializePatient(source, patientID);
    await cp(
      new URL("fixtures/patient-v1/valid/minimal/patient.yaml", repositoryRoot),
      join(source, "patients", patientID, "patient.yaml"),
    );
    const month = join(source, "appointments/2026/09");
    await mkdir(month, { recursive: true });
    await cp(
      new URL("fixtures/appointment-v1/valid/in-person/appointment.yaml", repositoryRoot),
      join(month, `${validID}.yaml`),
    );
    await cp(
      new URL("fixtures/appointment-v1/invalid/invalid-interval/appointment.yaml", repositoryRoot),
      join(month, `${invalidID}.yaml`),
    );

    const result = await inspectVaultDirectory(source);
    assert.deepEqual(result.valid_appointments, [validID]);
    assert.deepEqual(result.unavailable_appointments, [invalidID]);
    assert.equal(result.writing_allowed, true);
    assert.ok(result.items.some((item) =>
      item.scope === "appointment" &&
      item.rule === "appointment.invalid_interval"
    ));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test(
  "blocks a patient symlink without hiding another patient",
  { skip: process.platform === "win32" },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-patient-link-"));
    try {
      const source = await materializeEmptyVault(temporary);
      const validID = "pt_0198f5c2-0000-7000-8000-000000000001";
      const blockedID = "pt_0198f5c2-0000-7000-8000-000000000002";
      await materializePatient(source, validID);
      await materializePatient(source, blockedID);
      const outside = join(temporary, "outside.txt");
      await writeFile(outside, "synthetic outside bytes\n");
      await symlink(outside, join(source, "patients", blockedID, "content", "escape"));

      const result = await inspectVaultDirectory(source);
      assert.equal(result.readable, true);
      assert.deepEqual(result.valid_patients, [validID]);
      assert.deepEqual(result.unavailable_patients, [blockedID]);
      assert.ok(result.items.some((item) =>
        item.scope === "artifact" && item.status === "blocked" &&
        item.rule === "filesystem.symlink" && item.patient_id === blockedID
      ));
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test(
  "does not follow a vault root symlink",
  { skip: process.platform === "win32" },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-root-link-"));
    try {
      const source = await materializeEmptyVault(temporary);
      const linked = join(temporary, "linked-vault");
      await symlink(source, linked);
      const result = await inspectVaultDirectory(linked);
      assert.equal(result.readable, false);
      assert.equal(result.items[0]?.rule, "filesystem.root_symlink");
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

async function materializeScopedFixture(parent: string): Promise<string> {
  const source = await materializeEmptyVault(parent);
  const expectation = JSON.parse(await readFile(
    new URL("expectation.json", scopedFixture),
    "utf8",
  )) as {
    readonly valid_patients: string[];
    readonly unavailable_patients: string[];
  };
  for (const patientID of expectation.valid_patients) {
    await materializePatient(source, patientID);
  }
  for (const patientID of expectation.unavailable_patients) {
    await materializePatient(source, patientID, [".openpep", "content", "raw"]);
  }
  await cp(new URL("notes-for-user.txt", scopedFixture), join(source, "notes-for-user.txt"));
  return source;
}

async function materializeEmptyVault(parent: string): Promise<string> {
  const source = join(parent, "vault");
  await mkdir(join(source, "operations"), { recursive: true });
  for (const relativePath of [
    "vault.yaml",
    "README.txt",
    "operations/manifest.yaml",
  ]) {
    await cp(new URL(relativePath, emptyVault), join(source, relativePath));
  }
  const expectedTree = JSON.parse(await readFile(
    new URL("expected-tree.json", emptyVault),
    "utf8",
  )) as { readonly directories: string[] };
  for (const directory of expectedTree.directories) {
    await mkdir(join(source, directory), { recursive: true });
  }
  return realpath(source);
}

async function materializePatient(
  vault: string,
  patientID: string,
  directories = [".openpep", "content", "raw", "wiki"],
): Promise<void> {
  for (const directory of directories) {
    await mkdir(join(vault, "patients", patientID, directory), { recursive: true });
  }
}

const demoFixture = new URL("fixtures/demo-cardiology-v1/vault/", repositoryRoot);
const demoMarker = ".openpep-demo-directory";
const demoMarkerText = "OPENPEP_SYNTHETIC_DEMO_DIRECTORY_V1\n";

test("reads the demo vault and keeps it read-only", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-directory-demo-"));
  try {
    const source = join(temporary, "vault");
    await cp(demoFixture, source, { recursive: true });
    const inspection = await inspectVaultDirectory(source);
    assert.equal(inspection.ok, true);
    assert.equal(inspection.readable, true);
    assert.equal(inspection.writing_allowed, false);
    assert.equal(inspection.valid_patients.length, 20);
    assert.equal(
      inspection.items.filter((candidate) =>
        candidate.rule === "operations.demo_directory_marker"
      ).length,
      5,
    );
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("accepts the demo marker only with exact bytes, alone, in a demo vault", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-directory-marker-"));
  try {
    const cases: Array<[string, (ledger: string) => Promise<void>, boolean]> = [
      ["wrong bytes", (ledger) =>
        writeFile(join(ledger, demoMarker), "OPENPEP_SYNTHETIC_DEMO_DIRECTORY_V2\n"), true],
      ["symbolic link", async (ledger) => {
        await writeFile(join(temporary, "marker-target"), demoMarkerText);
        await symlink(join(temporary, "marker-target"), join(ledger, demoMarker));
      }, true],
      ["extra file", async (ledger) => {
        await writeFile(join(ledger, demoMarker), demoMarkerText);
        await writeFile(join(ledger, "synthetic.ops.ndjson"), "{}\n");
      }, true],
      ["non-demo vault", (ledger) =>
        writeFile(join(ledger, demoMarker), demoMarkerText), false],
    ];
    for (const [label, populate, demo] of cases) {
      const source = demo
        ? join(temporary, label.replaceAll(" ", "-"))
        : await materializeEmptyVault(join(temporary, "plain"));
      if (demo) {
        await cp(demoFixture, source, { recursive: true });
        await rm(join(source, "operations/ledger", demoMarker));
      }
      await populate(join(source, "operations/ledger"));
      const inspection = await inspectVaultDirectory(source);
      assert.equal(inspection.ok, false, label);
      assert.equal(inspection.readable, false, label);
      assert.equal(
        inspection.items.find((candidate) =>
          candidate.path === "operations/ledger"
        )?.rule,
        "operations.state_not_empty",
        label,
      );
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
