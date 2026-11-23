// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { ProtocolValidationError } from "../src/errors.js";
import {
  bindOperationsManifestToVault,
  readOperationsManifest,
  validateOperationsManifestYaml,
} from "../src/operations-manifest.js";
import { readVaultManifest } from "../src/validate.js";

const fixtureRoot = fileURLToPath(new URL(
  "../../../../fixtures/operations-manifest-v1/",
  import.meta.url,
));
const vaultFixture = fileURLToPath(new URL(
  "../../../../fixtures/vault-v1/valid/minimal/vault.yaml",
  import.meta.url,
));

test("accepts the empty operations manifest", async () => {
  const manifest = await readOperationsManifest(
    join(fixtureRoot, "valid/empty/manifest.yaml"),
  );
  assert.equal(manifest.schema, "openpep/operations-manifest@1");
  assert.equal(manifest.state, "empty");
});

test("rejects every persisted invalid operations manifest", async () => {
  const invalidRoot = join(fixtureRoot, "invalid");
  const cases = await readdir(invalidRoot, { withFileTypes: true });
  for (const fixtureCase of cases) {
    if (!fixtureCase.isDirectory()) {
      continue;
    }
    const manifestPath = join(invalidRoot, fixtureCase.name, "manifest.yaml");
    const expectation = JSON.parse(await readFile(
      join(dirname(manifestPath), "expectation.json"),
      "utf8",
    )) as { rule: string; path: string };
    await assert.rejects(readOperationsManifest(manifestPath), (error) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, expectation.rule);
      assert.equal(error.issues[0]?.path, expectation.path);
      return true;
    });
  }
});

test("binds the operations manifest to the root vault id", async () => {
  const operations = await readOperationsManifest(
    join(fixtureRoot, "valid/empty/manifest.yaml"),
  );
  const vault = await readVaultManifest(vaultFixture);
  assert.equal(bindOperationsManifestToVault(operations, vault), operations);

  const mismatched = validateOperationsManifestYaml(
    `schema: openpep/operations-manifest@1\n` +
      `vault_id: vlt_0198f5c0-7f36-7b65-9f31-11a0d536a220\n` +
      `state: empty\n`,
  );
  assert.throws(
    () => bindOperationsManifestToVault(mismatched, vault),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "operations.vault_id_mismatch");
      assert.equal(error.issues[0]?.path, "/vault_id");
      return true;
    },
  );
});

test("preserves namespaced extensions", () => {
  const manifest = validateOperationsManifestYaml(
    `schema: openpep/operations-manifest@1\n` +
      `vault_id: vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f\n` +
      `state: empty\n` +
      `x_profile: synthetic\n`,
  );
  assert.equal(manifest.x_profile, "synthetic");
});
