// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

export {
  bindAppointmentManifestToFile,
  readAppointmentManifest,
  validateAppointmentYaml,
  type AppointmentManifest,
} from "./appointment.js";
export {
  calculateClinicalEventHash,
  canonicalizeJson,
  sha256Hex,
  type CanonicalJson,
  type EventHashResult,
  type JsonPrimitive,
  type JsonValue,
} from "./canonical.js";
export {
  bindClinicalDraft,
  validateClinicalDraftMarkdown,
  validateEncounterMarkdown,
  type ClinicalAIGeneration,
  type ClinicalDraftDocument,
  type ClinicalDraftV3Document,
  type EncounterDocument,
  type ParsedClinicalDraft,
} from "./clinical-document.js";
export {
  checkpointExpectation,
  validateClinicalLedgerCheckpoint,
  type ClinicalLedgerCheckpoint,
} from "./checkpoint.js";
export {
  eventHashBody,
  validateClinicalEvent,
  type ClinicalEventBody,
  type ClinicalLedgerEvent,
} from "./clinical-event.js";
export {
  ProtocolValidationError,
  type ProtocolValidationIssue,
} from "./errors.js";
export {
  isOpenPepId,
  isUuidV7,
  openPepIdPrefixes,
  parseOpenPepId,
  type OpenPepIdType,
  type ParsedOpenPepId,
} from "./ids.js";
export {
  bindOperationsManifestToVault,
  readOperationsManifest,
  validateOperationsManifestYaml,
  type OperationsManifest,
} from "./operations-manifest.js";
export {
  bindPatientManifestToDirectory,
  readPatientManifest,
  validatePatientYaml,
  type PatientAlert,
  type PatientContact,
  type PatientIdentifier,
  type PatientManifest,
} from "./patient.js";
export {
  bindProgressiveSummaryWork,
  validateProgressiveSummaryWork,
  validateProgressiveSummaryWorkJson,
  type ProgressiveSummaryAcceptance,
  type ProgressiveSummaryBlock,
  type ProgressiveSummaryGeneration,
  type ProgressiveIncrementalSummary,
  type ProgressiveSummaryItem,
  type ProgressiveSummaryRange,
  type ProgressiveSummaryRevision,
  type ProgressiveSummarySegment,
  type ProgressiveSummarySegmentReference,
  type ProgressiveSummaryWorkBinding,
  type ProgressiveSummaryWorkDocument,
  type ProgressiveSummaryWorkStatus,
} from "./progressive-summary-work.js";
export {
  decodeClinicalLedgerBytes,
  maximumLedgerLineBytes,
  parseClinicalLedgerNdjson,
  verifyClinicalLedgerBytes,
  zeroEventHash,
  type ClinicalLedgerCheckpointExpectation,
  type ClinicalLedgerVerification,
  type ClinicalLedgerVerificationOptions,
  type ClinicalObjectResolver,
  type ParsedClinicalLedgerEvent,
} from "./ledger.js";
export {
  es256SignatureBytes,
  normalizeEs256Signature,
  p256PublicKeyX963Bytes,
  validateP256PublicKeyX963,
  verifyEs256EventHashSignature,
} from "./signatures.js";
export {
  findAuthorizedSigningKey,
  validateSigningKeyRegistry,
  type ClinicalSigningKey,
  type SigningKeyRegistry,
} from "./signing-keys.js";
export {
  decodeYamlBytes,
  isProtocolValidationError,
  maximumYamlBytes,
  maximumYamlLines,
  readYamlFileBytes,
  maximumYamlDepth,
  parseYamlSubset,
  type YamlValue,
} from "./yaml.js";
export {
  readVaultManifest,
  validateVaultYaml,
  type VaultManifest,
} from "./validate.js";
export {
  inspectVaultDirectory,
  type VaultDirectoryInspection,
  type VaultInspectionItem,
  type VaultInspectionScope,
  type VaultInspectionStatus,
} from "./vault-directory.js";
