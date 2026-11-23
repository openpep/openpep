// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  bindClinicalDraft,
  ProtocolValidationError,
  validateClinicalDraftMarkdown,
  validateEncounterMarkdown,
} from "../src/index.js";

const fixtureRoot = new URL(
  "../../../../fixtures/clinical-draft-v1/",
  import.meta.url,
);

test("reads the golden encounter and synthetic draft", async () => {
  const root = new URL("valid/synthetic-encounter/", fixtureRoot);
  const expectation = JSON.parse(
    await readFile(new URL("expectation.json", root), "utf8"),
  ) as ClinicalFixtureExpectation;
  const encounter = validateEncounterMarkdown(
    await readFile(new URL("encounter.md", root)),
    "encounter.md",
  );
  const draft = validateClinicalDraftMarkdown(
    await readFile(new URL("draft.md", root)),
    "draft.md",
  );

  bindClinicalDraft(encounter, draft.metadata, encounter.patient_id, "draft.md");
  assert.equal(encounter.status, "in_progress");
  assert.equal(draft.metadata.status, "draft");
  assert.equal(encounter.patient_id, expectation.patient_id);
  assert.equal(encounter.encounter_id, expectation.encounter_id);
  assert.equal(draft.metadata.note_id, expectation.note_id);
  assert.equal(encounter.created_by, expectation.author_id);
  assert.equal(draft.metadata.author_id, expectation.author_id);
  assert.equal(encounter.started_at, expectation.started_at);
  assert.equal(encounter.x_actor_assurance, "synthetic_unauthenticated");
  assert.equal(draft.metadata.x_actor_assurance, "synthetic_unauthenticated");
  assert.equal(draft.body, expectation.body);
  assert.equal(expectation.encounter_relative_path, `content/encounters/${encounter.encounter_id}.md`);
  assert.equal(expectation.draft_relative_path, `content/notes/drafts/${draft.metadata.note_id}.md`);
});

test("rejects unknown fields in encounter and draft", async () => {
  const cases = [
    "unknown-encounter-field/encounter.md",
    "unknown-draft-field/draft.md",
  ] as const;

  for (const relativePath of cases) {
    const bytes = await readFile(new URL(`invalid/${relativePath}`, fixtureRoot));
    const expectation = JSON.parse(await readFile(
      new URL(`invalid/${relativePath.replace(/[^/]+$/, "expectation.json")}`, fixtureRoot),
      "utf8",
    )) as RejectionExpectation;
    const validate = relativePath.endsWith("encounter.md")
      ? validateEncounterMarkdown
      : validateClinicalDraftMarkdown;
    assert.throws(
      () => validate(bytes, relativePath),
      (error: unknown) => error instanceof ProtocolValidationError &&
        error.issues[0]?.rule === expectation.rule &&
        error.issues[0]?.path === expectation.path,
    );
  }
});

test("rejects a draft bound to another patient", async () => {
  const root = new URL("invalid/mismatched-patient/", fixtureRoot);
  const expectation = JSON.parse(
    await readFile(new URL("expectation.json", root), "utf8"),
  ) as RejectionExpectation;
  const encounter = validateEncounterMarkdown(
    await readFile(new URL("encounter.md", root)),
  );
  const draft = validateClinicalDraftMarkdown(
    await readFile(new URL("draft.md", root)),
  );
  assert.throws(
    () => bindClinicalDraft(encounter, draft.metadata, encounter.patient_id, "draft.md"),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === expectation.rule &&
      error.issues[0]?.path === expectation.path,
  );
});

test("uses strict UTC RFC 3339 timestamps and accepts fractions", async () => {
  const source = await readFile(
    new URL("valid/synthetic-encounter/encounter.md", fixtureRoot),
    "utf8",
  );
  const fractional = source.replace(
    "2026-08-30T17:20:00Z",
    "2026-08-30T17:20:00.123Z",
  );
  assert.equal(
    validateEncounterMarkdown(Buffer.from(fractional)).started_at,
    "2026-08-30T17:20:00.123Z",
  );

  for (const timestamp of [
    "2026-8-30T17:20:00Z",
    "2026-02-29T17:20:00Z",
    "2026-08-30T17:20:60Z",
    "0000-02-29T17:20:00Z",
  ]) {
    const invalid = source.replace("2026-08-30T17:20:00Z", timestamp);
    assert.throws(
      () => validateEncounterMarkdown(Buffer.from(invalid)),
      ProtocolValidationError,
    );
  }
});

test("requires the unauthenticated synthetic actor assurance", async () => {
  const root = new URL("valid/synthetic-encounter/", fixtureRoot);
  for (const file of ["encounter.md", "draft.md"] as const) {
    const source = await readFile(new URL(file, root), "utf8");
    const validate = file === "encounter.md"
      ? validateEncounterMarkdown
      : validateClinicalDraftMarkdown;
    for (const invalid of [
      source.replace("x_actor_assurance: synthetic_unauthenticated\n", ""),
      source.replace("synthetic_unauthenticated", "verified_professional"),
    ]) {
      assert.throws(
        () => validate(Buffer.from(invalid)),
        ProtocolValidationError,
      );
    }
  }
});

test("checks every encounter and draft binding", async () => {
  const root = new URL("valid/synthetic-encounter/", fixtureRoot);
  const encounter = validateEncounterMarkdown(await readFile(new URL("encounter.md", root)));
  const draft = validateClinicalDraftMarkdown(await readFile(new URL("draft.md", root))).metadata;
  const anotherPatient = "pt_0198f5c2-0000-7000-8000-000000000002";

  for (const [changedEncounter, changedDraft, expectedPatientId, rule, path] of [
    [encounter, draft, anotherPatient, "clinical_document.patient_mismatch", "/patient_id"],
    [encounter, { ...draft, encounter_id: "enc_0198f5d1-0000-7000-8000-000000000002" }, encounter.patient_id, "clinical_document.encounter_mismatch", "/encounter_id"],
    [encounter, { ...draft, author_id: "usr_0198f4a0-0000-7000-8000-000000000002" }, encounter.patient_id, "clinical_document.author_mismatch", "/author_id"],
  ] as const) {
    assert.throws(
      () => bindClinicalDraft(changedEncounter, changedDraft, expectedPatientId),
      (error: unknown) => error instanceof ProtocolValidationError &&
        error.issues[0]?.rule === rule && error.issues[0]?.path === path,
    );
  }
});

test("keeps source_ids empty in the synthetic draft profile", async () => {
  const source = await readFile(
    new URL("valid/synthetic-encounter/draft.md", fixtureRoot),
    "utf8",
  );
  const invalid = source.replace(
    "source_ids: []",
    "source_ids:\n  - asset_0198f5c2-0000-7000-8000-000000000001",
  );
  assert.throws(
    () => validateClinicalDraftMarkdown(Buffer.from(invalid)),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "schema.maxItems" &&
      error.issues[0]?.path === "/source_ids",
  );
});

test("accepts reviewed AI provenance in clinical-note@2 and keeps @1 compatible", async () => {
  const legacy = validateClinicalDraftMarkdown(await readFile(
    new URL("valid/synthetic-encounter/draft.md", fixtureRoot),
  ));
  assert.equal(legacy.metadata.schema, "openpep/clinical-note@1");

  const assistedRoot = new URL("../../../../fixtures/clinical-draft-v2/", import.meta.url);
  const assistedURL = new URL("valid/reviewed-summary/draft.md", assistedRoot);
  const assistedSource = await readFile(assistedURL, "utf8");
  const assisted = validateClinicalDraftMarkdown(Buffer.from(assistedSource));
  assert.equal(assisted.metadata.schema, "openpep/clinical-note@2");
  assert.deepEqual(assisted.metadata.source_ids, [
    "asset_0198f5d7-0000-7000-8000-000000000201",
  ]);
  assert.equal(assisted.metadata.ai_assistance.used, true);
  assert.equal(assisted.metadata.ai_assistance.generation_id,
    "gen_0198f5d8-0000-7000-8000-000000000201");
  const extended = validateClinicalDraftMarkdown(Buffer.from(
    assistedSource.replace(
      "  chunk_count: 2",
      "  chunk_count: 2\n  x_review_note: synthetic",
    ),
  ));
  assert.equal(extended.metadata.ai_assistance.x_review_note, "synthetic");
  if (assisted.metadata.schema !== "openpep/clinical-note@2") {
    throw new Error("expected clinical-note@2 fixture");
  }

  const legacyEncounter = validateEncounterMarkdown(await readFile(
    new URL("valid/synthetic-encounter/encounter.md", fixtureRoot),
  ));
  const matchingEncounter = {
    ...legacyEncounter,
    patient_id: assisted.metadata.patient_id,
    encounter_id: assisted.metadata.encounter_id,
    created_by: assisted.metadata.author_id,
  };
  bindClinicalDraft(matchingEncounter, assisted.metadata, assisted.metadata.patient_id);
  const mismatchedReviewer = validateClinicalDraftMarkdown(Buffer.from(
    assistedSource.replace(
      "reviewed_by: usr_0198f4a0-0000-7000-8000-000000000201",
      "reviewed_by: usr_0198f4a0-0000-7000-8000-000000000202",
    ),
  ));
  assert.throws(
    () => bindClinicalDraft(
      matchingEncounter,
      mismatchedReviewer.metadata,
      assisted.metadata.patient_id,
    ),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "clinical_document.reviewer_mismatch" &&
      error.issues[0]?.path === "/ai_assistance/reviewed_by",
  );
});

test("rejects clinical-note@2 without an identified human reviewer", async () => {
  const root = new URL("../../../../fixtures/clinical-draft-v2/invalid/missing-reviewer/", import.meta.url);
  const awaitedBytes = await readFile(new URL("draft.md", root));
  assert.throws(
    () => validateClinicalDraftMarkdown(awaitedBytes),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues.some((issue) => issue.rule === "schema.required" &&
        issue.path === "/ai_assistance/reviewed_by"),
  );
});

test("accepts repeated AI generations in clinical-note@3 and rejects duplicates", async () => {
  const root = new URL("../../../../fixtures/clinical-draft-v3/", import.meta.url);
  const validSource = await readFile(
    new URL("valid/two-generations/draft.md", root),
    "utf8",
  );
  const valid = validateClinicalDraftMarkdown(Buffer.from(validSource));
  assert.equal(valid.metadata.schema, "openpep/clinical-note@3");
  if (valid.metadata.schema !== "openpep/clinical-note@3") {
    throw new Error("expected clinical-note@3 fixture");
  }
  assert.equal(valid.metadata.ai_assistance.generations.length, 2);
  assert.deepEqual(
    valid.metadata.ai_assistance.generations.map((item) => item.source_id),
    valid.metadata.source_ids,
  );
  assert.equal(valid.metadata.ai_assistance.generations[1]?.engine, "openai/responses");
  assert.equal(valid.metadata.ai_assistance.generations[1]?.model,
    "gpt-5.6-sol-2026-09-01");

  const encounter = validateEncounterMarkdown(await readFile(
    new URL("valid/synthetic-encounter/encounter.md", fixtureRoot),
  ));
  bindClinicalDraft({
    ...encounter,
    patient_id: valid.metadata.patient_id,
    encounter_id: valid.metadata.encounter_id,
    created_by: valid.metadata.author_id,
  }, valid.metadata, valid.metadata.patient_id);

  const duplicate = await readFile(new URL(
    "invalid/duplicate-generation/draft.md",
    root,
  ));
  assert.throws(
    () => validateClinicalDraftMarkdown(duplicate),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "clinical_document.duplicate_generation" &&
      error.issues[0]?.path === "/ai_assistance/generations",
  );

  const reversedSources = validSource.replace(
    `source_ids:
  - asset_0198f5d7-0000-7000-8000-000000000301
  - asset_0198f5d7-0000-7000-8000-000000000302`,
    `source_ids:
  - asset_0198f5d7-0000-7000-8000-000000000302
  - asset_0198f5d7-0000-7000-8000-000000000301`,
  );
  assert.throws(
    () => validateClinicalDraftMarkdown(Buffer.from(reversedSources)),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "clinical_document.ai_source_set_mismatch" &&
      error.issues[0]?.path === "/source_ids",
  );

  const missingOpenAIAcceptance = validSource.replace(
    '      accepted_at: "2026-09-05T10:10:00Z"',
    "      accepted_at: null",
  );
  assert.throws(
    () => validateClinicalDraftMarkdown(Buffer.from(missingOpenAIAcceptance)),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "schema.type" &&
      error.issues[0]?.path === "/ai_assistance/generations/1/accepted_at",
  );

  const mismatchRoot = new URL("invalid/provenance-mismatch/", root);
  const mismatchExpectation = JSON.parse(await readFile(
    new URL("expectation.json", mismatchRoot), "utf8",
  )) as RejectionExpectation;
  const mismatch = await readFile(new URL("draft.md", mismatchRoot));
  assert.throws(
    () => validateClinicalDraftMarkdown(mismatch),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === mismatchExpectation.rule &&
      error.issues[0]?.path === mismatchExpectation.path,
  );
});

test("accepts progressive-summary provenance in clinical-note@4", async () => {
  const root = new URL("../../../../fixtures/clinical-draft-v4/", import.meta.url);
  const validSource = await readFile(
    new URL("valid/two-generations/draft.md", root),
    "utf8",
  );
  const valid = validateClinicalDraftMarkdown(Buffer.from(validSource));
  assert.equal(valid.metadata.schema, "openpep/clinical-note@4");
  if (valid.metadata.schema !== "openpep/clinical-note@4") {
    throw new Error("expected clinical-note@4 fixture");
  }
  assert.equal(valid.metadata.ai_assistance.generations.length, 2);
  assert.deepEqual(
    valid.metadata.ai_assistance.generations.map((item) => item.source_id),
    valid.metadata.source_ids,
  );
  assert.equal(
    valid.metadata.ai_assistance.generations[0]?.engine,
    "apple/FoundationModels.SystemLanguageModel",
  );
  assert.equal(valid.metadata.ai_assistance.generations[1]?.model, "gpt-4o");

  for (const version of [3, 4, 5]) {
    const currentPrompt = validateClinicalDraftMarkdown(Buffer.from(
      validSource.replaceAll(
        "openpep/progressive-consultation-summary-pt-BR@1",
        `openpep/progressive-consultation-summary-pt-BR@${version}`,
      ),
    ));
    assert.equal(currentPrompt.metadata.schema, "openpep/clinical-note@4");
  }

  const finalApplePrompt = "openpep/final-consultation-summary-apple-pt-BR@1";
  const withFinalApple = validateClinicalDraftMarkdown(Buffer.from(
    validSource.replace(
      "openpep/progressive-consultation-summary-pt-BR@1",
      finalApplePrompt,
    ),
  ));
  assert.equal(withFinalApple.metadata.schema, "openpep/clinical-note@4");
  const withRemoteFinalApple = validSource
    .replace("openpep/progressive-consultation-summary-pt-BR@1", "first-prompt-placeholder")
    .replace("openpep/progressive-consultation-summary-pt-BR@1", finalApplePrompt)
    .replace("first-prompt-placeholder", "openpep/progressive-consultation-summary-pt-BR@1");
  assert.throws(() => validateClinicalDraftMarkdown(Buffer.from(withRemoteFinalApple)),
    (error: unknown) => error instanceof ProtocolValidationError &&
      error.issues[0]?.rule === "clinical_document.ai_provenance_profile");

  const preservedV3 = validateClinicalDraftMarkdown(Buffer.from((await readFile(
    new URL("../../../../fixtures/clinical-draft-v3/valid/two-generations/draft.md", import.meta.url),
    "utf8",
  )).replace("openpep/clinical-note@3", "openpep/clinical-note@4")));
  assert.equal(preservedV3.metadata.schema, "openpep/clinical-note@4");

  const encounter = validateEncounterMarkdown(await readFile(
    new URL("valid/synthetic-encounter/encounter.md", fixtureRoot),
  ));
  bindClinicalDraft({
    ...encounter,
    patient_id: valid.metadata.patient_id,
    encounter_id: valid.metadata.encounter_id,
    created_by: valid.metadata.author_id,
  }, valid.metadata, valid.metadata.patient_id);

  for (const name of [
    "openai-missing-response",
    "apple-with-model",
    "mismatched-sources",
  ]) {
    const invalidRoot = new URL(`invalid/${name}/`, root);
    const expectation = JSON.parse(await readFile(
      new URL("expectation.json", invalidRoot),
      "utf8",
    )) as RejectionExpectation;
    const invalid = await readFile(new URL("draft.md", invalidRoot));
    assert.throws(
      () => validateClinicalDraftMarkdown(invalid),
      (error: unknown) => error instanceof ProtocolValidationError &&
        error.issues[0]?.rule === expectation.rule &&
        error.issues[0]?.path === expectation.path,
    );
  }
});

test("accepts declared telemedicine facts without inferring them", async () => {
  const source = await readFile(
    new URL("valid/synthetic-encounter/encounter.md", fixtureRoot),
    "utf8",
  );
  const remote = source
    .replace(
      "appointment_id: null",
      "appointment_id: appt_0198f6c0-0000-7000-8000-000000000001",
    )
    .replace("modality: in_person", "modality: telemedicine")
    .replace(
      "created_by: usr_0198f4a0-0000-7000-8000-000000000001",
      `created_by: usr_0198f4a0-0000-7000-8000-000000000001
template_id: "file/consulta-livre.md"
template_version: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
telemedicine:
  consent: confirmed
  declared_location: "Manaus, AM"
  participants:
    - "Paciente sintético"
    - "Acompanhante sintético"
  limitations: "Vídeo indisponível no início"
  contingency: "Continuidade por áudio"`,
    );
  const encounter = validateEncounterMarkdown(Buffer.from(remote));
  assert.equal(encounter.modality, "telemedicine");
  assert.equal(encounter.telemedicine?.consent, "confirmed");
  assert.deepEqual(encounter.telemedicine?.participants, [
    "Paciente sintético",
    "Acompanhante sintético",
  ]);

  assert.throws(
    () => validateEncounterMarkdown(Buffer.from(
      remote.replace(/telemedicine:\n(?:  .*\n?)+(?=x_actor_assurance)/, ""),
    )),
    ProtocolValidationError,
  );
});

interface ClinicalFixtureExpectation {
  readonly schema: "openpep/fixture-expectation@1";
  readonly result: "accept";
  readonly patient_id: string;
  readonly encounter_id: string;
  readonly note_id: string;
  readonly author_id: string;
  readonly started_at: string;
  readonly encounter_relative_path: string;
  readonly draft_relative_path: string;
  readonly body: string;
}

interface RejectionExpectation {
  readonly schema: "openpep/fixture-expectation@1";
  readonly result: "reject";
  readonly rule: string;
  readonly path: string;
}
