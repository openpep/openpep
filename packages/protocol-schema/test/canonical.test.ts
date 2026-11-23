// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { ProtocolValidationError } from "../src/errors.js";
import {
  calculateClinicalEventHash,
  canonicalizeJson,
  sha256Hex,
} from "../src/canonical.js";

const goldenFixtureDirectory = fileURLToPath(
  new URL(
    "../../../../fixtures/clinical-ledger-v1/golden/first-event/",
    import.meta.url,
  ),
);

test("matches the RFC 8785 recursive sorting example", () => {
  const input = {
    "1": { f: { f: "hi", F: 5 }, "\n": 56 },
    "10": {},
    "": "empty",
    a: {},
    "111": [{ e: "yes", E: "no" }],
    A: {},
  };

  const result = canonicalizeJson(input);
  assert.equal(
    result.text,
    "{\"\":\"empty\",\"1\":{\"\\n\":56,\"f\":{\"F\":5,\"f\":\"hi\"}},\"10\":{},\"111\":[{\"E\":\"no\",\"e\":\"yes\"}],\"A\":{},\"a\":{}}",
  );
  assert.equal(new TextDecoder().decode(result.bytes), result.text);
});

test("preserves array order and Unicode bytes", () => {
  const decomposed = "cafe\u0301";
  const result = canonicalizeJson({ values: ["é", decomposed] });
  assert.equal(result.text, `{"values":["é","${decomposed}"]}`);
});

test("rejects values outside I-JSON before canonicalization", () => {
  const cases: Array<[unknown, string, string]> = [
    [{ value: Number.NaN }, "jcs.non_finite_number", "/value"],
    [{ value: Number.POSITIVE_INFINITY }, "jcs.non_finite_number", "/value"],
    [{ value: undefined }, "jcs.unsupported_value", "/value"],
    [{ value: 1n }, "jcs.unsupported_value", "/value"],
    [{ value: "\ud800" }, "jcs.lone_surrogate", "/value"],
    [{ value: new Date(0) }, "jcs.object_prototype", "/value"],
  ];

  for (const [input, expectedRule, expectedPath] of cases) {
    assert.throws(() => canonicalizeJson(input), (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, expectedRule);
      assert.equal(error.issues[0]?.path, expectedPath);
      return true;
    });
  }
});

test("rejects circular references", () => {
  const input: Record<string, unknown> = {};
  input.self = input;
  assert.throws(() => canonicalizeJson(input), (error: unknown) => {
    assert.ok(error instanceof ProtocolValidationError);
    assert.equal(error.issues[0]?.rule, "jcs.circular_reference");
    assert.equal(error.issues[0]?.path, "/self");
    return true;
  });
});

test("rejects executable, hidden and non-JSON properties", () => {
  const accessor: Record<string, unknown> = {};
  Object.defineProperty(accessor, "value", {
    enumerable: true,
    get() {
      throw new Error("getter must not execute");
    },
  });

  const hidden = {};
  Object.defineProperty(hidden, "value", {
    enumerable: false,
    value: "hidden",
  });

  const withSymbol = { value: "visible" } as Record<PropertyKey, unknown>;
  withSymbol[Symbol("hidden")] = "hidden";

  const withArrayProperty = ["value"] as unknown[] & { extra?: string };
  withArrayProperty.extra = "hidden";

  const sparse = new Array<unknown>(1);

  const cases: Array<[unknown, string, string]> = [
    [accessor, "jcs.property_descriptor", "/value"],
    [hidden, "jcs.property_descriptor", "/value"],
    [withSymbol, "jcs.property_key", "/"],
    [withArrayProperty, "jcs.array_property", "/"],
    [sparse, "jcs.sparse_array", "/0"],
  ];

  for (const [input, expectedRule, expectedPath] of cases) {
    assert.throws(() => canonicalizeJson(input), (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, expectedRule);
      assert.equal(error.issues[0]?.path, expectedPath);
      return true;
    });
  }
});

test("calculates the same event hash independent of property insertion order", () => {
  const previousEventHash = "00".repeat(32);
  const first = {
    schema: "openpep/clinical-event@1",
    sequence: 1,
    previous_event_hash: previousEventHash,
  };
  const second = {
    previous_event_hash: previousEventHash,
    sequence: 1,
    schema: "openpep/clinical-event@1",
  };

  const firstResult = calculateClinicalEventHash(first);
  const secondResult = calculateClinicalEventHash(second);
  assert.equal(firstResult.text, secondResult.text);
  assert.equal(firstResult.eventHash, secondResult.eventHash);
  assert.match(firstResult.eventHash, /^[0-9a-f]{64}$/);
});

test("does not accept proof fields or malformed previous hashes", () => {
  assert.throws(
    () => calculateClinicalEventHash({
      previous_event_hash: "00".repeat(32),
      event_hash: "11".repeat(32),
    }),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "ledger.proof_fields_present");
      return true;
    },
  );

  assert.throws(
    () => calculateClinicalEventHash({ previous_event_hash: "ABC" }),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "ledger.previous_event_hash");
      assert.equal(error.issues[0]?.path, "/previous_event_hash");
      return true;
    },
  );
});

test("hashes raw bytes with SHA-256 lowercase hex", () => {
  assert.equal(
    sha256Hex(new TextEncoder().encode("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

test("matches the golden first-event fixture", async () => {
  const event = JSON.parse(
    await readFile(`${goldenFixtureDirectory}/event.json`, "utf8"),
  ) as Record<string, unknown>;
  const expectation = JSON.parse(
    await readFile(`${goldenFixtureDirectory}/expectation.json`, "utf8"),
  ) as {
    object_sha256: string;
    event_hash: string;
  };
  const canonicalFile = await readFile(
    `${goldenFixtureDirectory}/canonical.json`,
    "utf8",
  );
  const objectBytes = await readFile(`${goldenFixtureDirectory}/object.txt`);

  assert.equal(sha256Hex(objectBytes), expectation.object_sha256);
  assert.equal(event.object_sha256, expectation.object_sha256);

  const result = calculateClinicalEventHash(event);
  assert.equal(canonicalFile.endsWith("\n"), true);
  assert.equal(canonicalFile.includes("\r"), false);
  const expectedCanonicalText = canonicalFile.slice(0, -1);
  assert.equal(expectedCanonicalText.includes("\n"), false);
  assert.equal(result.text, expectedCanonicalText);
  assert.deepEqual(
    result.bytes,
    new TextEncoder().encode(expectedCanonicalText),
  );
  assert.equal(result.eventHash, expectation.event_hash);

  const incorrectAsciiHexHash = createHash("sha256")
    .update(String(event.previous_event_hash), "utf8")
    .update(result.bytes)
    .digest("hex");
  assert.notEqual(result.eventHash, incorrectAsciiHexHash);
});
