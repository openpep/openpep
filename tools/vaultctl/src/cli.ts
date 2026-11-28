#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import {
  ProtocolValidationError,
  canonicalizeJson,
  checkpointExpectation,
  inspectVaultDirectory,
  readVaultManifest,
  validateClinicalLedgerCheckpoint,
  validateSigningKeyRegistry,
  verifyClinicalLedgerBytes,
  type ClinicalObjectResolver,
  type VaultManifest,
} from "@openpep/protocol-schema";
import { realpathSync } from "node:fs";
import { readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const vaultctlVersion = "0.4.0";
const maximumMetadataBytes = 1024 * 1024;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

const usage = `Uso:
  vaultctl validate <vault.yaml|vault-directory> [--json]
  vaultctl verify <ledger.ndjson> --keys <signing-keys.json> --objects <patient-directory> --checkpoint <checkpoint.json> [--json]
  vaultctl --version
  vaultctl --help

verify confere o ledger contra as chaves e o checkpoint recebidos e não
verifica a origem deles. Obtenha esses arquivos fora do cofre verificado: uma
cópia do próprio cofre pode ter sido alterada junto com o ledger.
`;

export interface VaultctlIo {
  readonly stdout: (text: string) => void;
  readonly stderr: (text: string) => void;
}

interface ValidateCommand {
  readonly kind: "validate";
  readonly source: string;
  readonly json: boolean;
}

interface VerifyCommand {
  readonly kind: "verify";
  readonly ledger: string;
  readonly keys: string;
  readonly objects: string;
  readonly checkpoint: string;
  readonly json: boolean;
}

type ParsedCommand =
  | { readonly kind: "help" }
  | { readonly kind: "version" }
  | ValidateCommand
  | VerifyCommand;

class UsageError extends Error {
  override readonly name = "UsageError";
}

const processIo: VaultctlIo = {
  stdout: (text) => process.stdout.write(text),
  stderr: (text) => process.stderr.write(text),
};

export async function runVaultctl(
  arguments_: readonly string[] = process.argv.slice(2),
  io: VaultctlIo = processIo,
): Promise<number> {
  const jsonRequested = arguments_.includes("--json");
  try {
    const command = parseArguments(arguments_);
    if (command.kind === "help") {
      io.stdout(usage);
      return 0;
    }
    if (command.kind === "version") {
      io.stdout(`${vaultctlVersion}\n`);
      return 0;
    }
    if (command.kind === "validate") {
      return await runValidate(command, io);
    }
    return await runVerify(command, io);
  } catch (error) {
    if (error instanceof ProtocolValidationError) {
      writeValidationFailure(error, jsonRequested, io);
      return 1;
    }
    if (error instanceof UsageError) {
      writeOperationalFailure("usage", error.message, jsonRequested, io);
      if (!jsonRequested) {
        io.stderr(usage);
      }
      return 2;
    }

    const message = error instanceof Error ? error.message : "falha desconhecida";
    writeOperationalFailure("operational", message, jsonRequested, io);
    return 2;
  }
}

async function runValidate(
  command: ValidateCommand,
  io: VaultctlIo,
): Promise<0 | 1> {
  let source = resolve(command.source);
  const metadata = await stat(source);

  if (metadata.isDirectory()) {
    const inspection = await inspectVaultDirectory(source);
    const result = { command: "validate", ...inspection } as const;
    if (command.json) {
      io.stdout(`${JSON.stringify(result)}\n`);
    } else {
      writeDirectoryInspection(result, io);
    }
    return inspection.ok ? 0 : 1;
  }
  if (!metadata.isFile()) {
    throw new Error(`não é arquivo nem diretório: ${source}`);
  }
  const manifest: VaultManifest = await readVaultManifest(source);
  const result = {
    ok: true,
    command: "validate",
    source,
    vault_id: manifest.vault_id,
    protocol_version: manifest.protocol_version,
    operations_manifest: "not_checked",
  } as const;
  if (command.json) {
    io.stdout(`${JSON.stringify(result)}\n`);
  } else {
    io.stdout(`manifesto válido: ${source}\n`);
    io.stdout(`vault: ${manifest.vault_id}\n`);
    io.stdout(`protocolo: ${manifest.protocol_version}\n`);
    io.stdout("manifesto operacional: não conferido\n");
  }
  return 0;
}

function writeDirectoryInspection(
  result: Awaited<ReturnType<typeof inspectVaultDirectory>> & {
    readonly command: "validate";
  },
  io: VaultctlIo,
): void {
  io.stdout(`cofre ${result.readable ? "legível" : "bloqueado"}: ${result.source}\n`);
  io.stdout(`vault: ${result.vault_id ?? "não identificado"}\n`);
  io.stdout(`protocolo: ${result.protocol_version ?? "não identificado"}\n`);
  io.stdout(`pacientes válidos: ${result.valid_patients.length}\n`);
  io.stdout(`pacientes indisponíveis: ${result.unavailable_patients.length}\n`);
  io.stdout(`agendamentos válidos: ${result.valid_appointments.length}\n`);
  io.stdout(`agendamentos indisponíveis: ${result.unavailable_appointments.length}\n`);
  io.stdout(`arquivos não gerenciados: ${result.unmanaged_paths.length}\n`);
  for (const diagnostic of result.items.filter((candidate) =>
    candidate.status !== "valid"
  )) {
    io.stdout(
      `${diagnostic.status} ${diagnostic.scope} ${diagnostic.path} [${diagnostic.rule}]\n`,
    );
  }
}

async function runVerify(
  command: VerifyCommand,
  io: VaultctlIo,
): Promise<0> {
  const ledgerPath = resolve(command.ledger);
  const keysPath = resolve(command.keys);
  const checkpointPath = resolve(command.checkpoint);
  const objectsPath = resolve(command.objects);
  const [ledger, keyValue, checkpointValue, objectResolver] = await Promise.all([
    readRegularFile(ledgerPath, maximumLedgerFileBytes),
    readJsonFile(keysPath),
    readJsonFile(checkpointPath),
    createSafeObjectResolver(objectsPath),
  ]);
  const signingKeyRegistry = validateSigningKeyRegistry(keyValue, keysPath);
  const checkpoint = validateClinicalLedgerCheckpoint(
    checkpointValue,
    checkpointPath,
  );
  const verification = await verifyClinicalLedgerBytes(
    ledger,
    {
      signingKeyRegistry,
      checkpoint: checkpointExpectation(checkpoint),
      resolveObject: objectResolver,
    },
    ledgerPath,
  );
  const result = {
    ok: true,
    command: "verify",
    ledger: ledgerPath,
    patient_id: verification.patientId,
    event_count: verification.eventCount,
    head_event_hash: verification.headEventHash,
    objects_verified: verification.objectsVerified,
    signatures: verification.signatures,
    signatures_verified: verification.signaturesVerified,
    checkpoint: "verified",
  } as const;

  if (command.json) {
    io.stdout(`${JSON.stringify(result)}\n`);
  } else {
    io.stdout(`ledger íntegro: ${ledgerPath}\n`);
    io.stdout(`paciente: ${verification.patientId ?? "vazio"}\n`);
    io.stdout(`eventos: ${verification.eventCount}\n`);
    io.stdout(`objetos verificados: ${verification.objectsVerified}\n`);
    io.stdout(`assinaturas verificadas: ${verification.signaturesVerified}\n`);
    io.stdout("checkpoint: verificado\n");
  }
  return 0;
}

function parseArguments(arguments_: readonly string[]): ParsedCommand {
  if (arguments_.length === 0) {
    throw new UsageError("informe um comando");
  }
  if (arguments_.includes("--help") || arguments_.includes("-h")) {
    return { kind: "help" };
  }
  if (arguments_.length === 1 && arguments_[0] === "--version") {
    return { kind: "version" };
  }

  const command = arguments_[0];
  const tokens = arguments_.slice(1);
  const json = removeBooleanOption(tokens, "--json");
  if (command === "validate") {
    const source = tokens[0];
    if (tokens.length !== 1 || source === undefined ||
        source.startsWith("--")) {
      throw new UsageError(
        "validate exige exatamente um vault.yaml ou diretório de vault",
      );
    }
    return { kind: "validate", source, json };
  }
  if (command === "verify") {
    const positional: string[] = [];
    const options = new Map<string, string>();
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index];
      if (token === undefined) {
        continue;
      }
      if (!token.startsWith("--")) {
        positional.push(token);
        continue;
      }
      if (!["--keys", "--objects", "--checkpoint"].includes(token)) {
        throw new UsageError(`opção desconhecida: ${token}`);
      }
      if (options.has(token)) {
        throw new UsageError(`opção repetida: ${token}`);
      }
      const value = tokens[index + 1];
      if (value === undefined || value.startsWith("--")) {
        throw new UsageError(`a opção ${token} exige um caminho`);
      }
      options.set(token, value);
      index += 1;
    }
    if (positional.length !== 1) {
      throw new UsageError("verify exige exatamente um arquivo ledger.ndjson");
    }
    const keys = options.get("--keys");
    const objects = options.get("--objects");
    const checkpoint = options.get("--checkpoint");
    if (keys === undefined || objects === undefined || checkpoint === undefined) {
      throw new UsageError(
        "verify exige --keys, --objects e --checkpoint",
      );
    }
    return {
      kind: "verify",
      ledger: positional[0] ?? "",
      keys,
      objects,
      checkpoint,
      json,
    };
  }
  throw new UsageError(`comando desconhecido: ${command ?? ""}`);
}

function removeBooleanOption(tokens: string[], option: string): boolean {
  let found = false;
  for (let index = tokens.length - 1; index >= 0; index -= 1) {
    if (tokens[index] === option) {
      if (found) {
        throw new UsageError(`opção repetida: ${option}`);
      }
      tokens.splice(index, 1);
      found = true;
    }
  }
  return found;
}

async function readJsonFile(filePath: string): Promise<unknown> {
  const metadata = await stat(filePath);
  if (!metadata.isFile()) {
    throw new Error(`não é um arquivo regular: ${filePath}`);
  }
  if (metadata.size > maximumMetadataBytes) {
    throw new Error(
      `o arquivo excede ${maximumMetadataBytes} bytes: ${filePath}`,
    );
  }
  const bytes = await readFile(filePath);
  let text: string;
  try {
    text = utf8Decoder.decode(bytes);
  } catch {
    throw new ProtocolValidationError([{
      source: filePath,
      path: "/",
      rule: "json.utf8",
      message: "o arquivo contém uma sequência UTF-8 inválida",
    }]);
  }
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new ProtocolValidationError([{
      source: filePath,
      path: "/",
      rule: "json.syntax",
      message: "o arquivo não contém JSON válido",
    }]);
  }
  if (text !== `${canonicalizeJson(value, filePath).text}\n`) {
    throw new ProtocolValidationError([{
      source: filePath,
      path: "/",
      rule: "json.non_canonical",
      message: "o arquivo deve conter JSON canônico RFC 8785 terminado por LF",
    }]);
  }
  return value;
}

async function createSafeObjectResolver(
  directoryPath: string,
): Promise<ClinicalObjectResolver> {
  const root = await realpath(directoryPath);
  const metadata = await stat(root);
  if (!metadata.isDirectory()) {
    throw new Error(`não é um diretório: ${directoryPath}`);
  }

  return async (relativePath) => {
    const candidate = resolve(root, relativePath);
    if (!isWithin(root, candidate)) {
      throw new Error("o caminho do objeto sai do diretório informado");
    }

    let actualPath: string;
    try {
      actualPath = await realpath(candidate);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        return undefined;
      }
      throw error;
    }
    if (!isWithin(root, actualPath)) {
      throw new Error("o caminho real do objeto sai do diretório informado");
    }
    return readRegularFile(actualPath, maximumObjectBytes);
  };
}

// The ledger and its objects come from the folder being checked: never block on a FIFO
// or read a file of unbounded size.
const maximumLedgerFileBytes = 64 * 1024 * 1024;
const maximumObjectBytes = 64 * 1024 * 1024;

async function readRegularFile(filePath: string, maximumBytes: number): Promise<Buffer> {
  const metadata = await stat(filePath);
  if (!metadata.isFile()) {
    throw new Error(`não é um arquivo regular: ${filePath}`);
  }
  if (metadata.size > maximumBytes) {
    throw new Error(`o arquivo excede ${maximumBytes} bytes: ${filePath}`);
  }
  return readFile(filePath);
}

function isWithin(root: string, target: string): boolean {
  const pathFromRoot = relative(root, target);
  return pathFromRoot !== "" && pathFromRoot !== ".." &&
    !pathFromRoot.startsWith(`..${sep}`) && !isAbsolute(pathFromRoot);
}

function writeValidationFailure(
  error: ProtocolValidationError,
  json: boolean,
  io: VaultctlIo,
): void {
  if (json) {
    io.stderr(`${JSON.stringify({
      ok: false,
      kind: "validation",
      issues: error.issues,
    })}\n`);
    return;
  }
  for (const issue of error.issues) {
    io.stderr(
      `falha [${issue.rule}] ${issue.source}${issue.path}: ${issue.message}\n`,
    );
  }
}

function writeOperationalFailure(
  kind: "usage" | "operational",
  message: string,
  json: boolean,
  io: VaultctlIo,
): void {
  if (json) {
    io.stderr(`${JSON.stringify({ ok: false, kind, message })}\n`);
  } else {
    io.stderr(`erro: ${message}\n`);
  }
}

function isDirectInvocation(): boolean {
  const invokedPath = process.argv[1];
  if (invokedPath === undefined) {
    return false;
  }
  try {
    return realpathSync(invokedPath) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (isDirectInvocation()) {
  process.exitCode = await runVaultctl();
}
