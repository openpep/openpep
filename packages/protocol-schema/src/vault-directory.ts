// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { lstat, readFile, readdir, realpath } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve, sep } from "node:path";
import { ProtocolValidationError } from "./errors.js";
import {
  bindAppointmentManifestToFile,
  readAppointmentManifest,
} from "./appointment.js";
import { isOpenPepId } from "./ids.js";
import {
  bindOperationsManifestToVault,
  readOperationsManifest,
} from "./operations-manifest.js";
import {
  bindPatientManifestToDirectory,
  readPatientManifest,
} from "./patient.js";
import { readVaultManifest, type VaultManifest } from "./validate.js";

export type VaultInspectionScope =
  | "vault"
  | "patient"
  | "appointment"
  | "artifact";
export type VaultInspectionStatus =
  | "valid"
  | "invalid"
  | "unmanaged"
  | "blocked";

export interface VaultInspectionItem {
  readonly scope: VaultInspectionScope;
  readonly status: VaultInspectionStatus;
  readonly path: string;
  readonly rule: string;
  readonly message: string;
  readonly patient_id?: string;
}

export interface VaultDirectoryInspection {
  readonly ok: boolean;
  readonly source: string;
  readonly vault_id: string | null;
  readonly protocol_version: string | null;
  readonly readable: boolean;
  readonly writing_allowed: boolean;
  readonly operations_manifest: "verified" | "missing" | "invalid";
  readonly valid_patients: readonly string[];
  readonly unavailable_patients: readonly string[];
  readonly valid_appointments: readonly string[];
  readonly unavailable_appointments: readonly string[];
  readonly unmanaged_paths: readonly string[];
  readonly items: readonly VaultInspectionItem[];
}

const requiredOperationsDirectories = [
  "operations/ledger",
  "operations/checkpoints",
  "operations/snapshots/patients",
  "operations/snapshots/appointments",
  "operations/snapshots/actions",
] as const;

const requiredPatientDirectories = [
  ".openpep",
  "content",
  "raw",
  "wiki",
] as const;

const knownRootEntries = new Set([
  "vault.yaml",
  "operations",
  "patients",
  "appointments",
  "indexes",
  "backups",
  "recovery",
  "recordings",
  "README.txt",
]);

// Optional SNCR number registries written by the prescribing flow, one per environment.
const prescribingRegistries = new Map([
  ["prescribing-homologation.json", "homologation"],
  ["prescribing-production.json", "production"],
]);
const prescribingRegistryLimit = 32 * 1024 * 1024;

export async function inspectVaultDirectory(
  source: string,
): Promise<VaultDirectoryInspection> {
  const requestedSource = resolve(source);
  const items: VaultInspectionItem[] = [];
  let manifest: VaultManifest | null = null;
  let canonicalSource = requestedSource;
  let operationsManifest: VaultDirectoryInspection["operations_manifest"] =
    "missing";

  const requestedMetadata = await lstat(requestedSource);
  if (requestedMetadata.isSymbolicLink()) {
    return blockedInspection(
      requestedSource,
      "filesystem.root_symlink",
      "o diretório do cofre não pode ser um link simbólico",
    );
  }
  if (!requestedMetadata.isDirectory()) {
    throw new Error(`não é um diretório de vault: ${requestedSource}`);
  }
  canonicalSource = await realpath(requestedSource);

  const manifestPath = join(canonicalSource, "vault.yaml");
  const manifestIssue = await managedFileIssue(manifestPath, "vault.yaml");
  if (manifestIssue !== null) {
    items.push(manifestIssue);
  } else {
    try {
      manifest = await readVaultManifest(manifestPath);
      items.push(item(
        "vault",
        "valid",
        "vault.yaml",
        "vault.manifest_valid",
        "manifesto raiz validado",
      ));
    } catch (error) {
      items.push(...protocolItems(error, "vault", "blocked", "vault.yaml"));
    }
  }

  if (manifest !== null) {
    const operationsPath = join(canonicalSource, "operations/manifest.yaml");
    const operationsIssue = await managedFileIssue(
      operationsPath,
      "operations/manifest.yaml",
      "invalid",
    );
    if (operationsIssue !== null) {
      items.push(operationsIssue);
    } else {
      try {
        const operations = await readOperationsManifest(operationsPath);
        bindOperationsManifestToVault(operations, manifest, operationsPath);
        operationsManifest = "verified";
        items.push(item(
          "vault",
          "valid",
          "operations/manifest.yaml",
          "operations.manifest_valid",
          "manifesto operacional validado",
        ));
      } catch (error) {
        operationsManifest = "invalid";
        items.push(...protocolItems(
          error,
          "vault",
          "blocked",
          "operations/manifest.yaml",
        ));
      }
    }
  }

  if (!hasBlockedVaultItem(items)) {
    items.push(...await inspectRootEntries(
      canonicalSource,
      manifest?.vault_id ?? null,
    ));
    items.push(...await inspectOperationsTree(canonicalSource));
  }

  const validPatients: string[] = [];
  const unavailablePatients: string[] = [];
  if (!hasBlockedVaultItem(items)) {
    const patientsResult = await inspectPatients(canonicalSource);
    items.push(...patientsResult.items);
    validPatients.push(...patientsResult.validPatients);
    unavailablePatients.push(...patientsResult.unavailablePatients);
  }

  const validAppointments: string[] = [];
  const unavailableAppointments: string[] = [];
  if (!hasBlockedVaultItem(items)) {
    const appointmentsResult = await inspectAppointments(
      canonicalSource,
      new Set(validPatients),
    );
    items.push(...appointmentsResult.items);
    validAppointments.push(...appointmentsResult.validAppointments);
    unavailableAppointments.push(...appointmentsResult.unavailableAppointments);
  }

  const rootBlocked = hasBlockedVaultItem(items);
  const unmanagedPaths = items
    .filter((candidate) => candidate.status === "unmanaged")
    .map((candidate) => candidate.path)
    .sort();
  return {
    ok: !items.some((candidate) =>
      candidate.status === "invalid" || candidate.status === "blocked"
    ),
    source: canonicalSource,
    vault_id: manifest?.vault_id ?? null,
    protocol_version: manifest?.protocol_version ?? null,
    readable: !rootBlocked,
    writing_allowed: !rootBlocked && operationsManifest === "verified",
    operations_manifest: operationsManifest,
    valid_patients: validPatients.sort(),
    unavailable_patients: unavailablePatients.sort(),
    valid_appointments: validAppointments.sort(),
    unavailable_appointments: unavailableAppointments.sort(),
    unmanaged_paths: unmanagedPaths,
    items,
  };
}

async function inspectAppointments(
  root: string,
  validPatients: ReadonlySet<string>,
): Promise<{
  readonly items: VaultInspectionItem[];
  readonly validAppointments: string[];
  readonly unavailableAppointments: string[];
}> {
  const appointmentsRoot = join(root, "appointments");
  const rootMetadata = await metadataOrNull(appointmentsRoot);
  if (rootMetadata === null) {
    return { items: [], validAppointments: [], unavailableAppointments: [] };
  }
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) {
    return {
      items: [item(
        "appointment",
        "blocked",
        "appointments",
        "filesystem.directory",
        "appointments deve ser um diretório sem link simbólico",
      )],
      validAppointments: [],
      unavailableAppointments: [],
    };
  }

  const items: VaultInspectionItem[] = [];
  const validAppointments: string[] = [];
  const unavailableAppointments: string[] = [];
  const seen = new Set<string>();
  for (const year of await readdir(appointmentsRoot, { withFileTypes: true })) {
    const yearPath = `appointments/${year.name}`;
    if (!/^\d{4}$/.test(year.name) || !year.isDirectory() || year.isSymbolicLink()) {
      items.push(item("appointment", "invalid", yearPath, "appointment.invalid_year_directory", "o diretório anual da agenda é inválido"));
      continue;
    }
    for (const month of await readdir(join(appointmentsRoot, year.name), { withFileTypes: true })) {
      const monthPath = `${yearPath}/${month.name}`;
      if (!/^(?:0[1-9]|1[0-2])$/.test(month.name) || !month.isDirectory() || month.isSymbolicLink()) {
        items.push(item("appointment", "invalid", monthPath, "appointment.invalid_month_directory", "o diretório mensal da agenda é inválido"));
        continue;
      }
      for (const file of await readdir(join(appointmentsRoot, year.name, month.name), { withFileTypes: true })) {
        const relativePath = `${monthPath}/${file.name}`;
        const candidateID = file.name.endsWith(".yaml")
          ? file.name.slice(0, -5)
          : file.name;
        if (!file.isFile() || file.isSymbolicLink() ||
            !isOpenPepId(candidateID, "appointment")) {
          items.push(item("appointment", file.isSymbolicLink() ? "blocked" : "invalid", relativePath, "appointment.invalid_file", "a entrada de agenda não usa arquivo e ID válidos"));
          if (isOpenPepId(candidateID, "appointment")) unavailableAppointments.push(candidateID);
          continue;
        }
        try {
          const appointment = bindAppointmentManifestToFile(
            await readAppointmentManifest(join(appointmentsRoot, year.name, month.name, file.name)),
            file.name,
            relativePath,
          );
          if (!validPatients.has(appointment.patient_id)) {
            throw new ProtocolValidationError([{
              source: relativePath,
              path: "/patient_id",
              rule: "appointment.patient_unavailable",
              message: "patient_id não identifica um paciente disponível",
            }]);
          }
          const localMonth = appointmentLocalMonth(
            appointment.starts_at,
            appointment.time_zone,
          );
          if (localMonth !== `${year.name}/${month.name}`) {
            throw new ProtocolValidationError([{
              source: relativePath,
              path: "/starts_at",
              rule: "appointment.path_month_mismatch",
              message: "o caminho mensal diverge do início no fuso gravado",
            }]);
          }
          if (seen.has(appointment.appointment_id)) {
            throw new ProtocolValidationError([{
              source: relativePath,
              path: "/appointment_id",
              rule: "appointment.duplicate_id",
              message: "appointment_id aparece em mais de um caminho",
            }]);
          }
          seen.add(appointment.appointment_id);
          validAppointments.push(appointment.appointment_id);
          items.push(item("appointment", "valid", relativePath, "appointment.manifest_valid", "agendamento validado", appointment.patient_id));
        } catch (error) {
          unavailableAppointments.push(candidateID);
          items.push(...protocolItems(error, "appointment", "invalid", relativePath));
        }
      }
    }
  }
  return { items, validAppointments, unavailableAppointments };
}

function appointmentLocalMonth(startsAt: string, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
  }).formatToParts(new Date(startsAt));
  const year = parts.find((part) => part.type === "year")?.value;
  const month = parts.find((part) => part.type === "month")?.value;
  return `${year}/${month}`;
}

async function inspectRootEntries(
  root: string,
  vaultID: string | null,
): Promise<VaultInspectionItem[]> {
  const items: VaultInspectionItem[] = [];
  const entries = await readdir(root, { withFileTypes: true });
  for (const entry of entries.sort((left, right) =>
    left.name.localeCompare(right.name)
  )) {
    const registryEnvironment = prescribingRegistries.get(entry.name);
    if (registryEnvironment !== undefined) {
      items.push(await inspectPrescribingRegistry(
        root,
        entry.name,
        registryEnvironment,
        vaultID,
      ));
      continue;
    }
    if (knownRootEntries.has(entry.name)) {
      const metadata = await lstat(join(root, entry.name));
      if (metadata.isSymbolicLink()) {
        items.push(item(
          "vault",
          "blocked",
          entry.name,
          "filesystem.symlink",
          "um caminho reservado da raiz é link simbólico",
        ));
      } else if (["recovery", "recordings"].includes(entry.name) && !metadata.isDirectory()) {
        items.push(item(
          "vault",
          "blocked",
          entry.name,
          "filesystem.directory",
          `${entry.name} deve ser um diretório sem link simbólico`,
        ));
      }
      continue;
    }
    const path = entry.name;
    if (entry.isFile()) {
      items.push(item(
        "vault",
        "unmanaged",
        path,
        "filesystem.unmanaged_regular_file",
        "arquivo regular preservado sem validação clínica",
      ));
    } else {
      items.push(item(
        "vault",
        "blocked",
        path,
        "filesystem.unmanaged_unsafe",
        "somente arquivo regular desconhecido é tolerado na raiz neste corte",
      ));
    }
  }
  return items;
}

// An unreadable or foreign registry blocks numbered prescribing only; patients,
// appointments and the rest of the vault stay available.
async function inspectPrescribingRegistry(
  root: string,
  name: string,
  environment: string,
  vaultID: string | null,
): Promise<VaultInspectionItem> {
  const path = join(root, name);
  const metadata = await lstat(path);
  if (metadata.isSymbolicLink()) {
    return item(
      "vault",
      "blocked",
      name,
      "filesystem.symlink",
      "um caminho reservado da raiz é link simbólico",
    );
  }
  const invalid = item(
    "artifact",
    "invalid",
    name,
    "prescribing.registry_invalid",
    "registro de números do receituário inválido; a emissão numerada fica bloqueada",
  );
  if (!metadata.isFile() || metadata.size > prescribingRegistryLimit) {
    return invalid;
  }
  try {
    const parsed: unknown = JSON.parse(await readFile(path, "utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return invalid;
    }
    const registry = parsed as Record<string, unknown>;
    if (
      registry.format !== "openpep-sncr-registry-v1" ||
      vaultID === null || registry.vaultID !== vaultID ||
      (registry.environment ?? "homologation") !== environment ||
      !Array.isArray(registry.requests) || !Array.isArray(registry.numbers)
    ) {
      return invalid;
    }
  } catch {
    return invalid;
  }
  return item(
    "artifact",
    "valid",
    name,
    "prescribing.registry_valid",
    "registro de números do receituário reconhecido",
  );
}

async function inspectOperationsTree(
  root: string,
): Promise<VaultInspectionItem[]> {
  const items: VaultInspectionItem[] = [];
  for (const relativePath of requiredOperationsDirectories) {
    const path = join(root, relativePath);
    const metadata = await metadataOrNull(path);
    if (metadata === null || !metadata.isDirectory() ||
        metadata.isSymbolicLink()) {
      items.push(item(
        "vault",
        "blocked",
        relativePath,
        "filesystem.required_directory",
        "o diretório operacional obrigatório está ausente ou é inseguro",
      ));
      continue;
    }
    if ((await readdir(path)).length > 0) {
      items.push(item(
        "vault",
        "blocked",
        relativePath,
        "operations.state_not_empty",
        "state empty diverge do conteúdo operacional",
      ));
    }
  }
  return items;
}

async function inspectPatients(root: string): Promise<{
  readonly items: VaultInspectionItem[];
  readonly validPatients: string[];
  readonly unavailablePatients: string[];
}> {
  const patientsRoot = join(root, "patients");
  const metadata = await metadataOrNull(patientsRoot);
  if (metadata === null || !metadata.isDirectory() || metadata.isSymbolicLink()) {
    return {
      items: [item(
        "vault",
        "blocked",
        "patients",
        "filesystem.required_directory",
        "patients deve ser um diretório sem link simbólico",
      )],
      validPatients: [],
      unavailablePatients: [],
    };
  }

  const items: VaultInspectionItem[] = [];
  const validPatients: string[] = [];
  const unavailablePatients: string[] = [];
  const patientEntries = await readdir(patientsRoot, { withFileTypes: true });
  for (const entry of patientEntries.sort((left, right) =>
    left.name.localeCompare(right.name)
  )) {
    const patientPath = `patients/${entry.name}`;
    const patientID = isOpenPepId(entry.name, "patient")
      ? entry.name
      : undefined;
    if (patientID === undefined || !entry.isDirectory() || entry.isSymbolicLink()) {
      items.push(item(
        "patient",
        entry.isSymbolicLink() ? "blocked" : "invalid",
        patientPath,
        patientID === undefined ? "patient.invalid_id" : "filesystem.directory",
        "a entrada de paciente não usa um diretório e ID válidos",
        patientID,
      ));
      if (patientID !== undefined) unavailablePatients.push(patientID);
      continue;
    }

    const patientResult = await inspectPatient(root, patientID);
    items.push(...patientResult);
    if (patientResult.some((candidate) =>
      candidate.status === "invalid" || candidate.status === "blocked"
    )) {
      unavailablePatients.push(patientID);
    } else {
      validPatients.push(patientID);
      items.push(item(
        "patient",
        "valid",
        patientPath,
        "patient.layout_valid",
        "estrutura de paciente validada",
        patientID,
      ));
    }
  }
  return { items, validPatients, unavailablePatients };
}

async function inspectPatient(
  root: string,
  patientID: string,
): Promise<VaultInspectionItem[]> {
  const patientRoot = join(root, "patients", patientID);
  const entries = (await readdir(patientRoot, { withFileTypes: true }))
    .sort((left, right) => left.name.localeCompare(right.name));
  const items: VaultInspectionItem[] = [];

  const patientManifestPath = join(patientRoot, "patient.yaml");
  const patientManifestMetadata = await metadataOrNull(patientManifestPath);
  if (patientManifestMetadata !== null) {
    const relativeManifestPath = `patients/${patientID}/patient.yaml`;
    if (!patientManifestMetadata.isFile() || patientManifestMetadata.isSymbolicLink()) {
      items.push(item(
        "patient",
        "blocked",
        relativeManifestPath,
        "filesystem.regular_file",
        "patient.yaml deve ser arquivo regular sem link simbólico",
        patientID,
      ));
    } else {
      try {
        const patient = await readPatientManifest(patientManifestPath);
        bindPatientManifestToDirectory(patient, patientID, relativeManifestPath);
        items.push(item(
          "patient",
          "valid",
          relativeManifestPath,
          "patient.manifest_valid",
          "cadastro do paciente validado",
          patientID,
        ));
      } catch (error) {
        items.push(...protocolItems(
          error,
          "patient",
          "invalid",
          relativeManifestPath,
        ).map((candidate) => ({ ...candidate, patient_id: patientID })));
      }
    }
  }

  for (const required of requiredPatientDirectories) {
    const relativePath = `patients/${patientID}/${required}`;
    const path = join(patientRoot, required);
    const metadata = await metadataOrNull(path);
    if (metadata === null || !metadata.isDirectory()) {
      items.push(item(
        "patient",
        "invalid",
        relativePath,
        "patient.required_directory",
        "o diretório obrigatório do paciente está ausente",
        patientID,
      ));
      continue;
    }
    if (metadata.isSymbolicLink()) {
      items.push(item(
        "patient",
        "blocked",
        relativePath,
        "filesystem.symlink",
        "o diretório do paciente não pode ser link simbólico",
        patientID,
      ));
      continue;
    }
    // wiki is a derived, independently validated cache. Its directory binding is
    // strict, but unknown or damaged contents must not make the clinical record
    // unavailable and are never followed here.
    if (required === "wiki") continue;
    const unsafePath = await firstSymbolicLink(path, root);
    if (unsafePath !== null) {
      items.push(item(
        "artifact",
        "blocked",
        unsafePath,
        "filesystem.symlink",
        "o conteúdo do paciente contém link simbólico",
        patientID,
      ));
    }
  }

  for (const entry of entries) {
    if (entry.name !== "patient.yaml" && !requiredPatientDirectories.includes(
      entry.name as typeof requiredPatientDirectories[number],
    )) {
      items.push(item(
        "patient",
        "invalid",
        `patients/${patientID}/${entry.name}`,
        "patient.unexpected_entry",
        "a raiz do paciente contém uma entrada fora do layout implementado",
        patientID,
      ));
    }
  }
  return items;
}

async function firstSymbolicLink(
  directory: string,
  root: string,
): Promise<string | null> {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const metadata = await lstat(path);
    if (metadata.isSymbolicLink()) {
      return relativePath(root, path);
    }
    if (metadata.isDirectory()) {
      const nested = await firstSymbolicLink(path, root);
      if (nested !== null) return nested;
    }
  }
  return null;
}

async function managedFileIssue(
  path: string,
  relativePath: string,
  missingStatus: VaultInspectionStatus = "blocked",
): Promise<VaultInspectionItem | null> {
  const metadata = await metadataOrNull(path);
  if (metadata === null) {
    return item(
      "vault",
      missingStatus,
      relativePath,
      "filesystem.required",
      "o manifesto obrigatório está ausente",
    );
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    return item(
      "vault",
      "blocked",
      relativePath,
      "filesystem.regular_file",
      "o manifesto deve ser arquivo regular sem link simbólico",
    );
  }
  return null;
}

async function metadataOrNull(path: string): Promise<Awaited<ReturnType<typeof lstat>> | null> {
  try {
    return await lstat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

function protocolItems(
  error: unknown,
  scope: VaultInspectionScope,
  status: VaultInspectionStatus,
  fallbackPath: string,
): VaultInspectionItem[] {
  if (error instanceof ProtocolValidationError) {
    return error.issues.map((issue) => item(
      scope,
      status,
      safeRelativeSource(issue.source, fallbackPath),
      issue.rule,
      issue.message,
    ));
  }
  throw error;
}

function safeRelativeSource(source: string, fallback: string): string {
  if (isAbsolute(source) || source.startsWith("<")) return fallback;
  const name = basename(source);
  return name.length > 0 && name !== "." ? name : fallback;
}

function hasBlockedVaultItem(items: readonly VaultInspectionItem[]): boolean {
  return items.some((candidate) =>
    candidate.scope === "vault" && candidate.status === "blocked"
  );
}

function relativePath(root: string, path: string): string {
  const value = relative(root, path);
  if (value === "" || value === ".." || value.startsWith(`..${sep}`)) {
    throw new Error("o caminho resolvido deixou a raiz do cofre");
  }
  return value.split(sep).join("/");
}

function blockedInspection(
  source: string,
  rule: string,
  message: string,
): VaultDirectoryInspection {
  return {
    ok: false,
    source,
    vault_id: null,
    protocol_version: null,
    readable: false,
    writing_allowed: false,
    operations_manifest: "missing",
    valid_patients: [],
    unavailable_patients: [],
    valid_appointments: [],
    unavailable_appointments: [],
    unmanaged_paths: [],
    items: [item("vault", "blocked", ".", rule, message)],
  };
}

function item(
  scope: VaultInspectionScope,
  status: VaultInspectionStatus,
  path: string,
  rule: string,
  message: string,
  patientID?: string,
): VaultInspectionItem {
  return {
    scope,
    status,
    path,
    rule,
    message,
    ...(patientID === undefined ? {} : { patient_id: patientID }),
  };
}
