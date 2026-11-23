// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import type { ClinicalLedgerEvent } from "../src/clinical-event.js";
import { ProtocolValidationError } from "../src/errors.js";
import {
  findAuthorizedSigningKey,
  validateSigningKeyRegistry,
  type SigningKeyRegistry,
} from "../src/signing-keys.js";
import {
  normalizeEs256Signature,
  validateP256PublicKeyX963,
  verifyEs256EventHashSignature,
} from "../src/signatures.js";

const goldenDirectory = fileURLToPath(
  new URL(
    "../../../../fixtures/clinical-ledger-v1/golden/two-events/",
    import.meta.url,
  ),
);

test("validates the golden signing-key registry", async () => {
  const registry = await readRegistry();
  assert.equal(registry.schema, "openpep/signing-key-registry@1");
  assert.equal(registry.keys[0]?.algorithm, "ES256");
  assert.equal(registry.keys[0]?.public_key_x963.length, 87);
});

test("the golden signature verifies against the registered key", async () => {
  const registry = await readRegistry();
  const event = await readFirstEvent();
  const key = registry.keys[0];
  assert.ok(key !== undefined);
  verifyEs256EventHashSignature(
    event.event_hash,
    event.signature,
    key.public_key_x963,
  );
});

test("uses IEEE P1363 signatures produced by a separate Node signer", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  });
  const jwk = publicKey.export({ format: "jwk" });
  if (jwk.x === undefined || jwk.y === undefined) {
    throw new Error("generated P-256 JWK lacks coordinates");
  }
  const publicKeyX963 = Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(jwk.x, "base64url"),
    Buffer.from(jwk.y, "base64url"),
  ]).toString("base64url");
  const eventHash = "ab".repeat(32);
  const signature = normalizeEs256Signature(sign(
    "sha256",
    Buffer.from(eventHash, "hex"),
    { key: privateKey, dsaEncoding: "ieee-p1363" },
  ).toString("base64url"));

  verifyEs256EventHashSignature(eventHash, signature, publicKeyX963);
});

test("rejects altered and malformed signatures", async () => {
  const registry = await readRegistry();
  const event = await readFirstEvent();
  const key = registry.keys[0];
  assert.ok(key !== undefined);
  const replacement = event.signature.startsWith("A") ? "B" : "A";
  const altered = `${replacement}${event.signature.slice(1)}`;

  assert.throws(
    () => verifyEs256EventHashSignature(
      event.event_hash,
      altered,
      key.public_key_x963,
    ),
    (error: unknown) => hasIssue(error, "ledger.signature_invalid"),
  );
  assert.throws(
    () => verifyEs256EventHashSignature(
      event.event_hash,
      `${event.signature}=`,
      key.public_key_x963,
    ),
    (error: unknown) => hasIssue(error, "ledger.signature_encoding"),
  );
  assert.throws(
    () => verifyEs256EventHashSignature(
      event.event_hash.toUpperCase(),
      event.signature,
      key.public_key_x963,
    ),
    (error: unknown) => hasIssue(error, "ledger.event_hash_encoding"),
  );
});

test("rejects the mathematically equivalent high-S form", async () => {
  const registry = await readRegistry();
  const event = await readFirstEvent();
  const key = registry.keys[0];
  assert.ok(key !== undefined);
  const signature = Buffer.from(event.signature, "base64url");
  const order = BigInt(
    "0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
  );
  const lowS = BigInt(`0x${signature.subarray(32).toString("hex")}`);
  const highS = (order - lowS).toString(16).padStart(64, "0");
  Buffer.from(highS, "hex").copy(signature, 32);

  assert.throws(
    () => verifyEs256EventHashSignature(
      event.event_hash,
      signature.toString("base64url"),
      key.public_key_x963,
    ),
    (error: unknown) => hasIssue(error, "ledger.signature_non_canonical"),
  );
});

test("rejects duplicate keys, invalid windows and invalid curve points", async () => {
  const registry = await readRegistry();
  const key = registry.keys[0];
  assert.ok(key !== undefined);

  assert.throws(
    () => validateSigningKeyRegistry({ ...registry, keys: [key, key] }),
    (error: unknown) => hasIssue(error, "signing_keys.duplicate_key_id"),
  );
  assert.throws(
    () => validateSigningKeyRegistry({
      ...registry,
      keys: [
        key,
        {
          ...key,
          key_id: "key_0198f5c1-0000-7000-8000-000000000099",
        },
      ],
    }),
    (error: unknown) => hasIssue(error, "signing_keys.duplicate_public_key"),
  );
  assert.throws(
    () => validateSigningKeyRegistry({
      ...registry,
      keys: [{
        ...key,
        authorized_until: key.authorized_from,
      }],
    }),
    (error: unknown) => hasIssue(error, "signing_keys.authorization_window"),
  );

  const invalidPoint = Buffer.alloc(65);
  invalidPoint[0] = 0x04;
  assert.throws(
    () => validateP256PublicKeyX963(invalidPoint.toString("base64url")),
    (error: unknown) => hasIssue(error, "ledger.public_key_invalid"),
  );
});

test("binds an authorized key to device and time window", async () => {
  const registry = await readRegistry();
  const event = await readFirstEvent();
  const key = findAuthorizedSigningKey(
    registry,
    event.signing_key_id,
    event.device_id,
    event.occurred_at,
  );
  assert.equal(key.key_id, event.signing_key_id);

  assert.throws(
    () => findAuthorizedSigningKey(
      registry,
      event.signing_key_id,
      "dev_0198f5c1-0000-7000-8000-000000000099",
      event.occurred_at,
    ),
    (error: unknown) => hasIssue(error, "ledger.signing_key_device"),
  );
  assert.throws(
    () => findAuthorizedSigningKey(
      registry,
      event.signing_key_id,
      event.device_id,
      "2026-08-30T16:59:59Z",
    ),
    (error: unknown) => hasIssue(error, "ledger.signing_key_not_authorized"),
  );
  assert.throws(
    () => findAuthorizedSigningKey(
      {
        ...registry,
        keys: registry.keys.map((candidate) => ({
          ...candidate,
          authorized_until: event.occurred_at,
        })),
      },
      event.signing_key_id,
      event.device_id,
      event.occurred_at,
    ),
    (error: unknown) => hasIssue(error, "ledger.signing_key_not_authorized"),
  );
  assert.throws(
    () => findAuthorizedSigningKey(
      registry,
      "key_0198f5c1-0000-7000-8000-000000000099",
      event.device_id,
      event.occurred_at,
    ),
    (error: unknown) => hasIssue(error, "ledger.signing_key_missing"),
  );
});

async function readRegistry(): Promise<SigningKeyRegistry> {
  return validateSigningKeyRegistry(
    JSON.parse(
      await readFile(join(goldenDirectory, "signing-keys.json"), "utf8"),
    ),
    "signing-keys.json",
  );
}

async function readFirstEvent(): Promise<ClinicalLedgerEvent> {
  const firstLine = (
    await readFile(join(goldenDirectory, "ledger.ndjson"), "utf8")
  ).split("\n")[0];
  assert.ok(firstLine !== undefined);
  return JSON.parse(firstLine) as ClinicalLedgerEvent;
}

function hasIssue(error: unknown, expectedRule: string): boolean {
  assert.ok(error instanceof ProtocolValidationError);
  assert.ok(error.issues.some((issue) => issue.rule === expectedRule));
  return true;
}
