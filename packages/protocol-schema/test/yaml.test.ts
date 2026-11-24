// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";
import { ProtocolValidationError } from "../src/errors.js";
import {
  decodeYamlBytes,
  maximumYamlBytes,
  maximumYamlLines,
  parseYamlSubset,
  readYamlFileBytes,
} from "../src/yaml.js";

function expectIssue(
  action: () => unknown,
  expectedRule: string,
  expectedPath: string,
): void {
  assert.throws(action, (error: unknown) => {
    assert.ok(error instanceof ProtocolValidationError);
    assert.equal(error.issues[0]?.rule, expectedRule);
    assert.equal(error.issues[0]?.path, expectedPath);
    return true;
  });
}

test("parses the portable scalar and collection subset", () => {
  const parsed = parseYamlSubset(
    "name: synthetic\nactive: true\ncount: 2\nempty: null\nitems:\n  - one\n",
  );
  assert.deepEqual({ ...parsed as object }, {
    name: "synthetic",
    active: true,
    count: 2,
    empty: null,
    items: ["one"],
  });
});

test("keeps dates as strings", () => {
  const parsed = parseYamlSubset("date: 2026-08-30\n") as {
    date: unknown;
  };
  assert.equal(parsed.date, "2026-08-30");
});

test("rejects aliases before resolving them", () => {
  expectIssue(
    () => parseYamlSubset("first: &value text\nsecond: *value\n"),
    "yaml.alias",
    "/second",
  );
});

test("rejects anchors without aliases", () => {
  expectIssue(
    () => parseYamlSubset("first: &value text\n"),
    "yaml.anchor",
    "/first",
  );
});

test("rejects explicit tags", () => {
  expectIssue(
    () => parseYamlSubset("value: !!str text\n"),
    "yaml.tag",
    "/value",
  );
});

test("rejects custom tags without resolving them", () => {
  assert.throws(
    () => parseYamlSubset("value: !openpep/object text\n"),
    (error: unknown) => {
      assert.ok(error instanceof ProtocolValidationError);
      assert.equal(error.issues[0]?.rule, "yaml.tag");
      assert.equal(error.issues[0]?.path, "/value");
      return true;
    },
  );
});

test("rejects duplicate keys", () => {
  expectIssue(
    () => parseYamlSubset("value: one\nvalue: two\n"),
    "yaml.syntax.duplicate_key",
    "line:2:column:1",
  );
});

test("rejects floats", () => {
  expectIssue(() => parseYamlSubset("value: 1.5\n"), "yaml.float", "/value");
});

test("rejects non-snake-case keys and merge keys", () => {
  expectIssue(
    () => parseYamlSubset("displayName: test\n"),
    "yaml.key_format",
    "/displayName",
  );
  expectIssue(
    () => parseYamlSubset("<<: test\n"),
    "yaml.merge_key",
    "/<<",
  );
});

test("rejects structures deeper than twelve levels", () => {
  let source = "";
  for (let index = 0; index < 13; index += 1) {
    source += `${"  ".repeat(index)}level_${index}:\n`;
  }
  source += `${"  ".repeat(13)}value: true\n`;
  assert.throws(() => parseYamlSubset(source), (error: unknown) => {
    assert.ok(error instanceof ProtocolValidationError);
    assert.equal(error.issues[0]?.rule, "yaml.maximum_depth");
    assert.ok(error.issues[0]?.path.startsWith("/level_0/level_1"));
    return true;
  });
});

test("accepts a collection depth of exactly twelve", () => {
  let source = "";
  for (let index = 0; index < 11; index += 1) {
    source += `${"  ".repeat(index)}level_${index}:\n`;
  }
  source += `${"  ".repeat(11)}value: true\n`;
  assert.doesNotThrow(() => parseYamlSubset(source));
});

test("rejects CRLF, BOM and non-NFC text", () => {
  expectIssue(
    () => parseYamlSubset("value: true\r\n"),
    "yaml.line_endings",
    "/",
  );
  expectIssue(
    () => parseYamlSubset("\uFEFFvalue: true\n"),
    "yaml.bom",
    "/",
  );
  expectIssue(
    () => parseYamlSubset("value: cafe\u0301\n"),
    "yaml.unicode_nfc",
    "/",
  );
});

test("rejects oversized and invalid UTF-8 input", () => {
  expectIssue(
    () => parseYamlSubset(`value: ${"a".repeat(maximumYamlBytes)}\n`),
    "yaml.maximum_size",
    "/",
  );
  expectIssue(
    () => decodeYamlBytes(Uint8Array.from([0xef, 0xbb, 0xbf, 0x61])),
    "yaml.bom",
    "/",
  );
  expectIssue(
    () => decodeYamlBytes(Uint8Array.from([0xc3, 0x28])),
    "yaml.utf8",
    "/",
  );
});

test("accepts input at the exact byte limit", () => {
  const prefix = "value: ";
  const source = `${prefix}${"a".repeat(
    maximumYamlBytes - Buffer.byteLength(prefix, "utf8") - 1,
  )}\n`;
  assert.equal(Buffer.byteLength(source, "utf8"), maximumYamlBytes);
  assert.doesNotThrow(() => parseYamlSubset(source));
});

test("refuses YAML with too many lines before the quadratic duplicate-key check", () => {
  const text = Array.from({ length: maximumYamlLines + 1 }, (_, index) => `k${index}: 1`).join("\n");
  assert.throws(
    () => parseYamlSubset(text, "synthetic.yaml"),
    (error: unknown) => error instanceof ProtocolValidationError && error.issues.some(issue => issue.rule === "yaml.resource_exhaustion"),
  );
});

test("reads YAML files only when they are regular and within the size limit", async () => {
  const { mkdtemp, rm, writeFile, symlink } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { execFileSync } = await import("node:child_process");
  const directory = await mkdtemp(join(tmpdir(), "openpep-yaml-"));
  try {
    const ok = join(directory, "ok.yaml");
    await writeFile(ok, "schema: synthetic\n");
    assert.equal(new TextDecoder().decode(await readYamlFileBytes(ok)), "schema: synthetic\n");
    const large = join(directory, "large.yaml");
    await writeFile(large, "x".repeat(maximumYamlBytes + 1));
    await assert.rejects(readYamlFileBytes(large), (error: unknown) => error instanceof ProtocolValidationError && error.issues[0]?.rule === "yaml.maximum_size");
    const link = join(directory, "link.yaml");
    await symlink(ok, link);
    await assert.rejects(readYamlFileBytes(link), (error: unknown) => error instanceof ProtocolValidationError && error.issues[0]?.rule === "yaml.not_regular_file");
    const fifo = join(directory, "fifo.yaml");
    execFileSync("mkfifo", [fifo]);
    await assert.rejects(readYamlFileBytes(fifo), (error: unknown) => error instanceof ProtocolValidationError && error.issues[0]?.rule === "yaml.not_regular_file");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
