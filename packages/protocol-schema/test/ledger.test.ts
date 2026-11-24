// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { canonicalizeJson } from "../src/canonical.js";
import { ProtocolValidationError } from "../src/errors.js";
import {
  decodeClinicalLedgerBytes,
  maximumLedgerLineBytes,
  parseClinicalLedgerNdjson,
  verifyClinicalLedgerBytes,
  zeroEventHash,
  type ClinicalLedgerCheckpointExpectation,
  type ClinicalObjectResolver,
} from "../src/ledger.js";
import {
  type SigningKeyRegistry,
  validateSigningKeyRegistry,
} from "../src/signing-keys.js";

const fixtureRoot = fileURLToPath(
  new URL(
    "../../../../fixtures/clinical-ledger-v1/",
    import.meta.url,
  ),
);
const goldenDirectory = join(fixtureRoot, "golden/two-events");

test("verifies the golden chain, checkpoint and referred objects", async () => {
  const ledger = await readFile(join(goldenDirectory, "ledger.ndjson"));
  const expectation = await readJson<{
    patient_id: string;
    event_count: number;
    head_event_hash: string;
    objects_verified: number;
    signatures: "verified";
    signatures_verified: number;
  }>(join(goldenDirectory, "expectation.json"));
  const signingKeyRegistry = await readSigningKeyRegistry();
  const result = await verifyClinicalLedgerBytes(
    ledger,
    {
      checkpoint: await readCheckpoint(
        join(goldenDirectory, "checkpoint.json"),
      ),
      resolveObject: fileResolver(join(goldenDirectory, "objects")),
      signingKeyRegistry,
    },
    "golden/ledger.ndjson",
  );

  assert.deepEqual(result, {
    patientId: expectation.patient_id,
    eventCount: expectation.event_count,
    headEventHash: expectation.head_event_hash,
    objectsVerified: expectation.objects_verified,
    signatures: expectation.signatures,
    signaturesVerified: expectation.signatures_verified,
  });
});

test("all persisted corrupt fixtures fail with the declared rule and path", async () => {
  const cases = [
    "reordered",
    "truncated-tail",
    "tampered-event",
    "noncanonical",
    "tampered-object",
    "tampered-signature",
  ];
  const signingKeyRegistry = await readSigningKeyRegistry();

  for (const fixtureName of cases) {
    const directory = join(fixtureRoot, "invalid", fixtureName);
    const expectation = await readJson<{
      checkpoint?: string;
      rule: string;
      path: string;
    }>(join(directory, "expectation.json"));
    const checkpoint = expectation.checkpoint === undefined
      ? undefined
      : await readCheckpoint(join(directory, expectation.checkpoint));
    const objectsDirectory = fixtureName === "tampered-object"
      ? join(directory, "objects")
      : undefined;

    await assert.rejects(
      verifyClinicalLedgerBytes(
        await readFile(join(directory, "ledger.ndjson")),
        {
          ...(checkpoint === undefined ? {} : { checkpoint }),
          ...(objectsDirectory === undefined
            ? {}
            : { resolveObject: fileResolver(objectsDirectory) }),
          signingKeyRegistry,
        },
        `${fixtureName}/ledger.ndjson`,
      ),
      (error: unknown) => hasIssue(error, expectation.rule, expectation.path),
      fixtureName,
    );
  }
});

test("rejects invalid encoding and NDJSON framing", async () => {
  const validLine = (await readFile(
    join(goldenDirectory, "ledger.ndjson"),
    "utf8",
  )).split("\n")[0] ?? "";
  const encoder = new TextEncoder();
  const cases: Array<[Uint8Array, string]> = [
    [Uint8Array.from([0xef, 0xbb, 0xbf, ...encoder.encode(`${validLine}\n`)]), "ledger.bom"],
    [Uint8Array.from([0xc3, 0x28]), "ledger.utf8"],
    [encoder.encode(`${validLine}\r\n`), "ledger.crlf"],
    [encoder.encode(validLine), "ledger.truncated_line"],
    [encoder.encode(`${validLine}\n\n`), "ledger.blank_line"],
    [encoder.encode("not-json\n"), "ledger.json_syntax"],
    [encoder.encode("[]\n"), "ledger.root_object"],
    [encoder.encode('{"schema":"one","schema":"two"}\n'), "ledger.non_canonical_line"],
  ];

  for (const [bytes, expectedRule] of cases) {
    await assert.rejects(
      verifyClinicalLedgerBytes(bytes),
      (error: unknown) => hasIssue(error, expectedRule),
      expectedRule,
    );
  }
});

test("limits each event line before parsing it", () => {
  assert.throws(
    () => parseClinicalLedgerNdjson(`${"x".repeat(maximumLedgerLineBytes + 1)}\n`),
    (error: unknown) => hasIssue(error, "ledger.line_too_large"),
  );
});

test("detects sequence, patient, duplicate id and previous-hash breaks", async () => {
  const events = await readGoldenEvents();
  const first = events[0];
  const second = events[1];
  assert.ok(first !== undefined && second !== undefined);
  const signingKeyRegistry = await readSigningKeyRegistry();
  const cases: Array<[Record<string, unknown>[], string, string]> = [
    [[{ ...first, sequence: 2 }], "ledger.sequence", "/lines/1/sequence"],
    [[first, { ...second, patient_id: "pt_0198f5c2-0000-7000-8000-000000000099" }], "ledger.patient_id", "/lines/2/patient_id"],
    [[first, { ...second, event_id: first.event_id }], "ledger.duplicate_event_id", "/lines/2/event_id"],
    [[first, { ...second, previous_event_hash: zeroEventHash }], "ledger.previous_event_hash", "/lines/2/previous_event_hash"],
  ];

  for (const [events, expectedRule, expectedPath] of cases) {
    await assert.rejects(
      verifyClinicalLedgerBytes(
        encodeCanonicalLedger(events),
        { signingKeyRegistry },
      ),
      (error: unknown) => hasIssue(error, expectedRule, expectedPath),
      expectedRule,
    );
  }
});

test("a checkpoint detects tail removal that a chain prefix alone cannot", async () => {
  const ledgerText = await readFile(join(goldenDirectory, "ledger.ndjson"), "utf8");
  const firstLineOnly = `${ledgerText.split("\n")[0] ?? ""}\n`;
  const prefixResult = await verifyClinicalLedgerBytes(
    new TextEncoder().encode(firstLineOnly),
    { signingKeyRegistry: await readSigningKeyRegistry() },
  );
  assert.equal(prefixResult.eventCount, 1);

  await assert.rejects(
    verifyClinicalLedgerBytes(
      new TextEncoder().encode(firstLineOnly),
      {
        checkpoint: await readCheckpoint(join(goldenDirectory, "checkpoint.json")),
        signingKeyRegistry: await readSigningKeyRegistry(),
      },
    ),
    (error: unknown) => hasIssue(error, "ledger.checkpoint_count"),
  );
});

test("a checkpoint also detects an unexpected final hash", async () => {
  const ledger = await readFile(join(goldenDirectory, "ledger.ndjson"));
  const checkpoint = await readCheckpoint(
    join(goldenDirectory, "checkpoint.json"),
  );
  await assert.rejects(
    verifyClinicalLedgerBytes(ledger, {
      checkpoint: { ...checkpoint, headEventHash: zeroEventHash },
      signingKeyRegistry: await readSigningKeyRegistry(),
    }),
    (error: unknown) => hasIssue(error, "ledger.checkpoint_hash"),
  );
});

test("rejects missing, unreadable and altered referred objects", async () => {
  const ledger = await readFile(join(goldenDirectory, "ledger.ndjson"));
  const signingKeyRegistry = await readSigningKeyRegistry();
  await assert.rejects(
    verifyClinicalLedgerBytes(ledger, {
      resolveObject: () => undefined,
      signingKeyRegistry,
    }),
    (error: unknown) => hasIssue(error, "ledger.object_missing"),
  );
  await assert.rejects(
    verifyClinicalLedgerBytes(ledger, {
      signingKeyRegistry,
      resolveObject: () => {
        throw new Error("synthetic read failure");
      },
    }),
    (error: unknown) => hasIssue(error, "ledger.object_unreadable"),
  );
  await assert.rejects(
    verifyClinicalLedgerBytes(ledger, {
      signingKeyRegistry,
      resolveObject: () => new TextEncoder().encode("altered"),
    }),
    (error: unknown) => hasIssue(error, "ledger.object_hash"),
  );
});

test("decodes an empty ledger as a valid empty chain", async () => {
  assert.equal(decodeClinicalLedgerBytes(new Uint8Array()), "");
  const result = await verifyClinicalLedgerBytes(new Uint8Array());
  assert.deepEqual(result, {
    patientId: null,
    eventCount: 0,
    headEventHash: zeroEventHash,
    objectsVerified: 0,
    signatures: "verified",
    signaturesVerified: 0,
  });
});

test("signature verification is fail-closed unless explicitly skipped", async () => {
  const ledger = await readFile(join(goldenDirectory, "ledger.ndjson"));
  await assert.rejects(
    verifyClinicalLedgerBytes(ledger),
    (error: unknown) => hasIssue(error, "ledger.signing_key_registry"),
  );

  const result = await verifyClinicalLedgerBytes(ledger, {
    signaturePolicy: "not_checked",
  });
  assert.equal(result.signatures, "not_checked");
  assert.equal(result.signaturesVerified, 0);
});

async function readGoldenEvents(): Promise<Record<string, unknown>[]> {
  const text = await readFile(join(goldenDirectory, "ledger.ndjson"), "utf8");
  return text.trimEnd().split("\n").map((line) =>
    JSON.parse(line) as Record<string, unknown>
  );
}

function encodeCanonicalLedger(events: readonly Record<string, unknown>[]): Uint8Array {
  return new TextEncoder().encode(
    `${events.map((event) => canonicalizeJson(event).text).join("\n")}\n`,
  );
}

function fileResolver(root: string): ClinicalObjectResolver {
  return async (relativePath) => {
    try {
      return await readFile(join(root, relativePath));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        return undefined;
      }
      throw error;
    }
  };
}

async function readCheckpoint(
  path: string,
): Promise<ClinicalLedgerCheckpointExpectation> {
  const checkpoint = await readJson<{
    patient_id: string;
    event_count: number;
    head_event_hash: string;
  }>(path);
  return {
    patientId: checkpoint.patient_id,
    eventCount: checkpoint.event_count,
    headEventHash: checkpoint.head_event_hash,
  };
}

async function readSigningKeyRegistry(): Promise<SigningKeyRegistry> {
  return validateSigningKeyRegistry(
    await readJson<unknown>(join(goldenDirectory, "signing-keys.json")),
    "signing-keys.json",
  );
}

async function readJson<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, "utf8")) as T;
}

function hasIssue(
  error: unknown,
  expectedRule: string,
  expectedPath?: string,
): boolean {
  assert.ok(error instanceof ProtocolValidationError);
  assert.ok(
    error.issues.some((issue) =>
      issue.rule === expectedRule &&
      (expectedPath === undefined || issue.path === expectedPath)
    ),
    `${expectedRule} ${expectedPath ?? ""}`,
  );
  return true;
}

test("an event dated before the previous one is refused before key authorization", async () => {
  const ledgerText = await readFile(join(goldenDirectory, "ledger.ndjson"), "utf8");
  const backdated = ledgerText.replace('"occurred_at":"2026-08-30T18:05:00Z"', '"occurred_at":"2026-08-30T17:05:00Z"');
  assert.notEqual(backdated, ledgerText);
  await assert.rejects(
    verifyClinicalLedgerBytes(new TextEncoder().encode(backdated), {
      signingKeyRegistry: await readSigningKeyRegistry(),
    }),
    (error: unknown) => hasIssue(error, "ledger.occurred_at_order", "/lines/2/occurred_at"),
  );
});
