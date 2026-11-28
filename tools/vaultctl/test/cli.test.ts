// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmod,
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
import { fileURLToPath } from "node:url";
import { runVaultctl, vaultctlVersion, type VaultctlIo } from "../src/cli.js";

const repositoryRoot = fileURLToPath(new URL("../../../../", import.meta.url));
const vaultFixtures = join(repositoryRoot, "fixtures/vault-v1");
const directoryFixtures = join(repositoryRoot, "fixtures/vault-directory-v1");
const ledgerFixtures = join(repositoryRoot, "fixtures/clinical-ledger-v1");
const golden = join(ledgerFixtures, "golden/two-events");

test("reports help and version without touching files", async () => {
  const help = captureIo();
  assert.equal(await runVaultctl(["--help"], help.io), 0);
  assert.match(help.stdout, /vaultctl verify/);
  assert.match(help.stdout, /não\s+verifica a origem/);

  const version = captureIo();
  assert.equal(await runVaultctl(["--version"], version.io), 0);
  assert.equal(version.stdout, `${vaultctlVersion}\n`);

  const entrypoint = fileURLToPath(new URL("../src/cli.js", import.meta.url));
  const child = spawnSync(process.execPath, [entrypoint, "--version"], {
    encoding: "utf8",
  });
  assert.equal(child.status, 0);
  assert.equal(child.stdout, `${vaultctlVersion}\n`);
  assert.equal(child.stderr, "");
});

test("validates a vault manifest in human and JSON formats", async () => {
  const source = join(vaultFixtures, "valid/minimal/vault.yaml");
  const human = captureIo();
  assert.equal(await runVaultctl(["validate", source], human.io), 0);
  assert.match(human.stdout, /manifesto válido:/);
  assert.match(human.stdout, /vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f/);
  assert.equal(human.stderr, "");

  const json = captureIo();
  assert.equal(await runVaultctl(["validate", source, "--json"], json.io), 0);
  assert.deepEqual(JSON.parse(json.stdout), {
    ok: true,
    command: "validate",
    source,
    vault_id: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
    protocol_version: "1.0",
    operations_manifest: "not_checked",
  });
});

test("validates the complete empty vault directory", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-valid-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const canonicalSource = await realpath(source);
    const io = captureIo();
    assert.equal(await runVaultctl(["validate", source, "--json"], io.io), 0);
    assert.deepEqual(JSON.parse(io.stdout), {
      ok: true,
      command: "validate",
      source: canonicalSource,
      vault_id: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
      protocol_version: "1.0",
      readable: true,
      writing_allowed: true,
      operations_manifest: "verified",
      valid_patients: [],
      unavailable_patients: [],
      valid_appointments: [],
      unavailable_appointments: [],
      unmanaged_paths: [],
      items: [
        {
          scope: "vault",
          status: "valid",
          path: "vault.yaml",
          rule: "vault.manifest_valid",
          message: "manifesto raiz validado",
        },
        {
          scope: "vault",
          status: "valid",
          path: "operations/manifest.yaml",
          rule: "operations.manifest_valid",
          message: "manifesto operacional validado",
        },
      ],
    });
    assert.equal(io.stderr, "");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("rejects a mismatched or non-empty operations manifest", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-bundle-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const operationsPath = join(source, "operations/manifest.yaml");
    await writeFile(
      operationsPath,
      `schema: openpep/operations-manifest@1\n` +
        `vault_id: vlt_0198f5c0-7f36-7b65-9f31-11a0d536a220\n` +
        `state: empty\n`,
    );

    const mismatch = captureIo();
    assert.equal(
      await runVaultctl(["validate", source, "--json"], mismatch.io),
      1,
    );
    assert.equal(
      JSON.parse(mismatch.stdout).items.find((item: { status: string }) =>
        item.status === "blocked"
      ).rule,
      "operations.vault_id_mismatch",
    );
    assert.equal(mismatch.stderr, "");

    await writeFile(
      operationsPath,
      await readFile(join(
        vaultFixtures,
        "valid/empty-vault/operations/manifest.yaml",
      )),
    );
    await writeFile(
      join(source, "operations/ledger/synthetic.ops.ndjson"),
      "{}\n",
    );
    const nonEmpty = captureIo();
    assert.equal(
      await runVaultctl(["validate", source, "--json"], nonEmpty.io),
      1,
    );
    assert.equal(
      JSON.parse(nonEmpty.stdout).items.find((item: { status: string }) =>
        item.status === "blocked"
      ).rule,
      "operations.state_not_empty",
    );
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("requires the operations manifest when validating a directory", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-missing-"));
  try {
    const source = await materializeEmptyVault(temporary);
    await rm(join(source, "operations/manifest.yaml"));
    const io = captureIo();
    assert.equal(await runVaultctl(["validate", source, "--json"], io.io), 1);
    const result = JSON.parse(io.stdout) as {
      readonly readable: boolean;
      readonly writing_allowed: boolean;
      readonly items: Array<{ readonly status: string; readonly rule: string }>;
    };
    assert.equal(result.readable, true);
    assert.equal(result.writing_allowed, false);
    assert.equal(
      result.items.find((item) => item.status === "invalid")?.rule,
      "filesystem.required",
    );
    assert.equal(io.stderr, "");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("validates the synthetic demo vault as readable and read-only", async () => {
  const io = captureIo();
  assert.equal(
    await runVaultctl(
      ["validate", join(repositoryRoot, "fixtures/demo-cardiology-v1/vault"), "--json"],
      io.io,
    ),
    0,
  );
  const result = JSON.parse(io.stdout) as {
    readonly readable: boolean;
    readonly writing_allowed: boolean;
    readonly valid_patients: readonly string[];
  };
  assert.equal(result.readable, true);
  assert.equal(result.writing_allowed, false);
  assert.equal(result.valid_patients.length, 20);
  assert.equal(io.stderr, "");
});

test(
  "summarizes the vault when one patient directory is unreadable",
  { skip: process.platform === "win32" || process.getuid?.() === 0 },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-io-"));
    const source = join(temporary, "vault");
    await cp(join(repositoryRoot, "fixtures/demo-cardiology-v1/vault"), source, {
      recursive: true,
    });
    const patientID = "pt_01990003-0000-7000-8000-000000000301";
    const locked = join(source, "patients", patientID, "content");
    try {
      await chmod(locked, 0o000);
      const io = captureIo();
      assert.equal(await runVaultctl(["validate", source, "--json"], io.io), 1);
      const result = JSON.parse(io.stdout) as {
        readonly readable: boolean;
        readonly valid_patients: readonly string[];
        readonly unavailable_patients: readonly string[];
        readonly items: Array<{ readonly status: string; readonly rule: string }>;
      };
      assert.equal(result.readable, true);
      assert.equal(result.valid_patients.length, 19);
      assert.deepEqual(result.unavailable_patients, [patientID]);
      assert.ok(result.items.some((item) =>
        item.status === "blocked" && item.rule === "filesystem.unreadable"
      ));
      assert.equal(io.stderr, "");
    } finally {
      await chmod(locked, 0o755);
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test("reports localized patients and unmanaged files in stable JSON", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-scoped-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const fixture = join(directoryFixtures, "scoped-isolation");
    const expectation = JSON.parse(await readFile(
      join(fixture, "expectation.json"),
      "utf8",
    )) as {
      readonly valid_patients: string[];
      readonly unavailable_patients: string[];
      readonly unmanaged_paths: string[];
    };
    for (const patientID of expectation.valid_patients) {
      await materializePatient(source, patientID);
    }
    for (const patientID of expectation.unavailable_patients) {
      await materializePatient(source, patientID, [".openpep", "content", "raw"]);
    }
    await cp(
      join(fixture, expectation.unmanaged_paths[0]!),
      join(source, expectation.unmanaged_paths[0]!),
    );

    const io = captureIo();
    assert.equal(await runVaultctl(["validate", source, "--json"], io.io), 1);
    const result = JSON.parse(io.stdout) as {
      readonly readable: boolean;
      readonly writing_allowed: boolean;
      readonly valid_patients: string[];
      readonly unavailable_patients: string[];
      readonly unmanaged_paths: string[];
    };
    assert.equal(result.readable, true);
    assert.equal(result.writing_allowed, true);
    assert.deepEqual(result.valid_patients, expectation.valid_patients);
    assert.deepEqual(
      result.unavailable_patients,
      expectation.unavailable_patients,
    );
    assert.deepEqual(result.unmanaged_paths, expectation.unmanaged_paths);
    assert.equal(io.stderr, "");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("validates a registered patient without exposing its fields", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-patient-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const patientID = "pt_0198f5c2-0000-7000-8000-000000000001";
    await materializePatient(source, patientID);
    await cp(
      join(repositoryRoot, "fixtures/patient-v1/valid/minimal/patient.yaml"),
      join(source, "patients", patientID, "patient.yaml"),
    );
    const io = captureIo();
    assert.equal(await runVaultctl(["validate", source, "--json"], io.io), 0);
    const result = JSON.parse(io.stdout) as {
      readonly valid_patients: string[];
      readonly items: Array<{ readonly rule: string; readonly message: string }>;
    };
    assert.deepEqual(result.valid_patients, [patientID]);
    assert.ok(result.items.some((item) => item.rule === "patient.manifest_valid"));
    assert.doesNotMatch(io.stdout, /Ana Fictícia/);
    assert.equal(io.stderr, "");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("validates a registered appointment without exposing patient or link fields", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-appointment-"));
  try {
    const source = await materializeEmptyVault(temporary);
    const patientID = "pt_0198f5c2-0000-7000-8000-000000000001";
    const appointmentID = "appt_0198f6c0-0000-7000-8000-000000000002";
    await materializePatient(source, patientID);
    await cp(
      join(repositoryRoot, "fixtures/patient-v1/valid/minimal/patient.yaml"),
      join(source, "patients", patientID, "patient.yaml"),
    );
    const month = join(source, "appointments/2026/09");
    await mkdir(month, { recursive: true });
    await cp(
      join(repositoryRoot, "fixtures/appointment-v1/valid/telemedicine/appointment.yaml"),
      join(month, `${appointmentID}.yaml`),
    );
    const io = captureIo();
    assert.equal(await runVaultctl(["validate", source, "--json"], io.io), 0);
    const result = JSON.parse(io.stdout) as {
      readonly valid_appointments: string[];
    };
    assert.deepEqual(result.valid_appointments, [appointmentID]);
    assert.doesNotMatch(io.stdout, /Ana Fictícia/);
    assert.doesNotMatch(io.stdout, /synthetic-room/);
    assert.equal(io.stderr, "");
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("returns a stable validation failure for an invalid manifest", async () => {
  const io = captureIo();
  const source = join(vaultFixtures, "invalid/unknown-field/vault.yaml");
  assert.equal(
    await runVaultctl(["validate", source, "--json"], io.io),
    1,
  );
  const failure = JSON.parse(io.stderr) as {
    kind: string;
    issues: Array<{ rule: string; path: string }>;
  };
  assert.equal(failure.kind, "validation");
  assert.ok(failure.issues.some((issue) =>
    issue.rule === "schema.additionalProperties" &&
    issue.path === "/doctor_name"
  ));
  assert.equal(io.stdout, "");
});

test("verifies the signed golden ledger and every referred object", async () => {
  const human = captureIo();
  assert.equal(await runVaultctl(goldenVerifyArguments(), human.io), 0);
  assert.match(human.stdout, /ledger íntegro:/);
  assert.match(human.stdout, /assinaturas verificadas: 2/);
  assert.equal(human.stderr, "");

  const io = captureIo();
  assert.equal(await runVaultctl([...goldenVerifyArguments(), "--json"], io.io), 0);
  assert.deepEqual(JSON.parse(io.stdout), {
    ok: true,
    command: "verify",
    ledger: join(golden, "ledger.ndjson"),
    patient_id: "pt_0198f5c2-0000-7000-8000-000000000001",
    event_count: 2,
    head_event_hash: "74d0f12aa384b7b91d4d12287b67b58868e87669977309b49f90a294204fc008",
    objects_verified: 2,
    signatures: "verified",
    signatures_verified: 2,
    checkpoint: "verified",
  });
  assert.equal(io.stderr, "");
});

test("rejects non-canonical security metadata", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-json-"));
  try {
    const keys = join(temporary, "signing-keys.json");
    const value = JSON.parse(
      await readFile(join(golden, "signing-keys.json"), "utf8"),
    ) as unknown;
    await writeFile(keys, `${JSON.stringify(value, null, 2)}\n`);

    const io = captureIo();
    assert.equal(
      await runVaultctl(
        verifyArguments(
          join(golden, "ledger.ndjson"),
          join(golden, "objects"),
          true,
          keys,
        ),
        io.io,
      ),
      1,
    );
    const failure = JSON.parse(io.stderr) as {
      issues: Array<{ rule: string }>;
    };
    assert.ok(failure.issues.some((issue) =>
      issue.rule === "json.non_canonical"
    ));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("rejects an altered signature and an altered object", async () => {
  const cases = [
    {
      ledger: join(ledgerFixtures, "invalid/tampered-signature/ledger.ndjson"),
      objects: join(golden, "objects"),
      rule: "ledger.signature_invalid",
    },
    {
      ledger: join(ledgerFixtures, "invalid/tampered-object/ledger.ndjson"),
      objects: join(ledgerFixtures, "invalid/tampered-object/objects"),
      rule: "ledger.object_hash",
    },
  ];

  for (const fixture of cases) {
    const io = captureIo();
    assert.equal(
      await runVaultctl(verifyArguments(fixture.ledger, fixture.objects, true), io.io),
      1,
    );
    const failure = JSON.parse(io.stderr) as {
      issues: Array<{ rule: string }>;
    };
    assert.ok(failure.issues.some((issue) => issue.rule === fixture.rule));
    assert.equal(io.stdout, "");
  }
});

test("requires keys, objects and checkpoint for a complete verification", async () => {
  const io = captureIo();
  assert.equal(
    await runVaultctl(["verify", join(golden, "ledger.ndjson"), "--json"], io.io),
    2,
  );
  assert.deepEqual(JSON.parse(io.stderr), {
    ok: false,
    kind: "usage",
    message: "verify exige --keys, --objects e --checkpoint",
  });
});

test(
  "rejects an object whose symbolic link leaves the supplied directory",
  { skip: process.platform === "win32" },
  async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openpep-vaultctl-"));
    try {
      const objects = join(temporary, "objects");
      const finalDirectory = join(objects, "content/notes/final");
      const addendaDirectory = join(objects, "content/notes/addenda");
      await mkdir(finalDirectory, { recursive: true });
      await mkdir(addendaDirectory, { recursive: true });

      const finalName = "note_0198f5d3-0000-7000-8000-000000000001.md";
      const addendumName = "note_0198f5d6-0000-7000-8000-000000000002.md";
      const outside = join(temporary, "outside.md");
      await writeFile(
        outside,
        await readFile(join(golden, "objects/content/notes/final", finalName)),
      );
      await symlink(outside, join(finalDirectory, finalName));
      await writeFile(
        join(addendaDirectory, addendumName),
        await readFile(join(golden, "objects/content/notes/addenda", addendumName)),
      );

      const io = captureIo();
      assert.equal(
        await runVaultctl(verifyArguments(
          join(golden, "ledger.ndjson"),
          objects,
          true,
        ), io.io),
        1,
      );
      const failure = JSON.parse(io.stderr) as {
        issues: Array<{ rule: string }>;
      };
      assert.ok(failure.issues.some((issue) =>
        issue.rule === "ledger.object_unreadable"
      ));
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

function goldenVerifyArguments(): string[] {
  return verifyArguments(
    join(golden, "ledger.ndjson"),
    join(golden, "objects"),
    false,
  );
}

async function materializeEmptyVault(parent: string): Promise<string> {
  const source = join(parent, "vault");
  const fixture = join(vaultFixtures, "valid/empty-vault");
  await mkdir(join(source, "operations"), { recursive: true });
  for (const relativePath of [
    "vault.yaml",
    "README.txt",
    "operations/manifest.yaml",
  ]) {
    await cp(join(fixture, relativePath), join(source, relativePath));
  }
  const expectedTree = JSON.parse(await readFile(
    join(fixture, "expected-tree.json"),
    "utf8",
  )) as { directories: string[] };
  for (const directory of expectedTree.directories) {
    await mkdir(join(source, directory), { recursive: true });
  }
  return source;
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

function verifyArguments(
  ledger: string,
  objects: string,
  json: boolean,
  keys = join(golden, "signing-keys.json"),
): string[] {
  return [
    "verify",
    ledger,
    "--keys",
    keys,
    "--objects",
    objects,
    "--checkpoint",
    join(golden, "checkpoint.json"),
    ...(json ? ["--json"] : []),
  ];
}

function captureIo(): {
  readonly io: VaultctlIo;
  readonly stdout: string;
  readonly stderr: string;
} {
  let stdout = "";
  let stderr = "";
  return {
    io: {
      stdout: (text) => {
        stdout += text;
      },
      stderr: (text) => {
        stderr += text;
      },
    },
    get stdout() {
      return stdout;
    },
    get stderr() {
      return stderr;
    },
  };
}
