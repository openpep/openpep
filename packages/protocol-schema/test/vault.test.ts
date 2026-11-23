// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { ProtocolValidationError } from "../src/errors.js";
import { readVaultManifest, validateVaultYaml } from "../src/validate.js";

const validFixture = fileURLToPath(
  new URL(
    "../../../../fixtures/vault-v1/valid/minimal/vault.yaml",
    import.meta.url,
  ),
);
const invalidAliasFixture = fileURLToPath(
  new URL(
    "../../../../fixtures/vault-v1/invalid/alias-forbidden/vault.yaml",
    import.meta.url,
  ),
);

test("accepts the minimal vault fixture", async () => {
  const manifest = await readVaultManifest(validFixture);
  assert.equal(manifest.schema, "openpep/vault@1");
  assert.equal(manifest.protocol_version, "1.0");
  assert.equal(manifest.clinical_writer.device_id.startsWith("dev_"), true);
});

test("rejects the alias fixture", async () => {
  await assert.rejects(readVaultManifest(invalidAliasFixture), (error) => {
    assert.ok(error instanceof ProtocolValidationError);
    assert.equal(error.issues[0]?.rule, "yaml.alias");
    assert.equal(error.issues[0]?.path, "/clinical_writer/device_id");
    return true;
  });
});

test("reports missing required fields with their field path", () => {
  assert.throws(
    () => validateVaultYaml("schema: openpep/vault@1\n", "incomplete.yaml"),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.ok(error.issues.some((issue) => issue.path === "/vault_id"));
      assert.ok(error.issues.every((issue) => issue.source === "incomplete.yaml"));
      return true;
    },
  );
});

test("rejects unknown fields and preserves x_ extensions", async () => {
  const source = await import("node:fs/promises").then(({ readFile }) =>
    readFile(validFixture, "utf8"),
  );

  assert.throws(
    () => validateVaultYaml(`${source}doctor_name: Example\n`),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.ok(
        error.issues.some((issue) =>
          issue.rule === "schema.additionalProperties" &&
          issue.path === "/doctor_name"),
      );
      return true;
    },
  );

  const extended = validateVaultYaml(`${source}x_test_profile: synthetic\n`);
  assert.equal(extended.x_test_profile, "synthetic");
});

test("requires UTC RFC 3339 timestamps and UUIDv7 identifiers", async () => {
  const source = await import("node:fs/promises").then(({ readFile }) =>
    readFile(validFixture, "utf8"),
  );

  assert.throws(() =>
    validateVaultYaml(
      source.replace(
        "2026-08-30T17:00:00Z",
        "2026-08-30T14:00:00-03:00",
      ),
    ),
  );
  assert.throws(() =>
    validateVaultYaml(
      source.replace(
        "0198f5c0-7f36-7b65-9f31-11a0d536a21f",
        "550e8400-e29b-41d4-a716-446655440000",
      ),
    ),
  );
});
