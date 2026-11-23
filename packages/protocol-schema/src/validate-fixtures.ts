// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { readFile, readdir } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { ProtocolValidationError } from "./errors.js";
import { readAppointmentManifest } from "./appointment.js";
import { readOperationsManifest } from "./operations-manifest.js";
import { readPatientManifest } from "./patient.js";
import { readVaultManifest } from "./validate.js";

const fixtureRoot = resolve(process.argv[2] ?? "../../fixtures/vault-v1");
const fixtureKind = process.argv[3] ?? "vault";
if (fixtureKind !== "vault" && fixtureKind !== "operations" &&
    fixtureKind !== "patient" && fixtureKind !== "appointment") {
  throw new Error(`tipo de fixture desconhecido: ${fixtureKind}`);
}
const fixtureFileName = fixtureKind === "vault"
  ? "vault.yaml"
  : fixtureKind === "operations"
  ? "manifest.yaml"
  : fixtureKind === "patient"
  ? "patient.yaml"
  : "appointment.yaml";
const readManifest = fixtureKind === "vault"
  ? readVaultManifest
  : fixtureKind === "operations"
  ? readOperationsManifest
  : fixtureKind === "patient"
  ? readPatientManifest
  : readAppointmentManifest;
const validCases = await findFixtureCases(resolve(fixtureRoot, "valid"));
const invalidCases = await findFixtureCases(resolve(fixtureRoot, "invalid"));
const fixtureCases = [...validCases, ...invalidCases];
const misplacedCases = [
  ...validCases.filter((item) => item.expectation.result !== "accept"),
  ...invalidCases.filter((item) => item.expectation.result !== "reject"),
];

if (validCases.length === 0 || invalidCases.length === 0) {
  console.error("erro: fixtures válidas e inválidas são obrigatórias");
  process.exitCode = 1;
} else if (misplacedCases.length > 0) {
  for (const fixtureCase of misplacedCases) {
    console.error(
      `erro: resultado incompatível com o diretório: ${relative(
        fixtureRoot,
        fixtureCase.filePath,
      )}`,
    );
  }
  process.exitCode = 1;
} else {
  let failures = 0;

  for (const fixtureCase of fixtureCases) {
    const displayPath = relative(fixtureRoot, fixtureCase.filePath);
    try {
      await readManifest(fixtureCase.filePath);
      if (fixtureCase.expectation.result === "accept") {
        console.log(`ok: aceita ${displayPath}`);
      } else {
        failures += 1;
        console.error(`erro: deveria rejeitar ${displayPath}`);
      }
    } catch (error) {
      if (fixtureCase.expectation.result === "accept") {
        failures += 1;
        console.error(`erro: deveria aceitar ${displayPath}`);
        console.error(error instanceof Error ? error.message : String(error));
      } else if (error instanceof ProtocolValidationError) {
        const firstIssue = error.issues[0];
        if (firstIssue !== undefined &&
            firstIssue.rule === fixtureCase.expectation.rule &&
            firstIssue.path === fixtureCase.expectation.path) {
          console.log(
            `ok: rejeita ${displayPath} [${firstIssue.rule} ${firstIssue.path}]`,
          );
        } else {
          failures += 1;
          console.error(`erro: rejeição inesperada em ${displayPath}`);
          console.error(error.message);
        }
      } else {
        failures += 1;
        console.error(`erro inesperado em ${displayPath}`);
        console.error(error instanceof Error ? error.message : String(error));
      }
    }
  }

  if (failures > 0) {
    process.exitCode = 1;
  } else {
    console.log(
      `fixtures verificadas: ${validCases.length} válida(s), ${invalidCases.length} inválida(s)`,
    );
  }
}

interface FixtureExpectation {
  readonly schema: "openpep/fixture-expectation@1";
  readonly result: "accept" | "reject";
  readonly rule?: string;
  readonly path?: string;
}

interface FixtureCase {
  readonly filePath: string;
  readonly expectation: FixtureExpectation;
}

async function findFixtureCases(directory: string): Promise<FixtureCase[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const cases: FixtureCase[] = [];

  for (const entry of entries) {
    const entryPath = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      cases.push(...await findFixtureCases(entryPath));
    } else if (entry.isFile() && entry.name === fixtureFileName) {
      cases.push({
        filePath: entryPath,
        expectation: await readExpectation(entryPath),
      });
    }
  }

  return cases.sort((left, right) => left.filePath.localeCompare(right.filePath));
}

async function readExpectation(filePath: string): Promise<FixtureExpectation> {
  const expectationPath = resolve(dirname(filePath), "expectation.json");
  const parsed = JSON.parse(await readFile(expectationPath, "utf8")) as
    Partial<FixtureExpectation>;

  if (parsed.schema !== "openpep/fixture-expectation@1" ||
      (parsed.result !== "accept" && parsed.result !== "reject")) {
    throw new Error(`expectativa inválida: ${expectationPath}`);
  }
  if (parsed.result === "reject" &&
      (typeof parsed.rule !== "string" || typeof parsed.path !== "string")) {
    throw new Error(`regra e caminho são obrigatórios: ${expectationPath}`);
  }
  if (parsed.result === "accept" &&
      (parsed.rule !== undefined || parsed.path !== undefined)) {
    throw new Error(`caso aceito não declara erro: ${expectationPath}`);
  }

  return parsed as FixtureExpectation;
}
