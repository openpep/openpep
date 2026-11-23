// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import OpenPEP

struct OpenPEPTests {
    private let invalidManifestCases = [
        "alias-forbidden",
        "anchor-forbidden",
        "duplicate-key",
        "float-forbidden",
        "invalid-device-id",
        "invalid-vault-id",
        "key-format",
        "maximum-depth",
        "merge-key-forbidden",
        "missing-vault-id",
        "non-utc-created-at",
        "tag-forbidden",
        "unknown-field",
        "unknown-writer-field",
        "wrong-canonicalization",
        "wrong-encryption-mode",
        "wrong-hash-algorithm",
        "wrong-protocol-version",
        "wrong-schema",
        "wrong-storage-mode",
    ]
    private let invalidOperationsManifestCases = [
        "invalid-vault-id",
        "missing-state",
        "missing-vault-id",
        "unknown-field",
        "wrong-schema",
        "wrong-state",
    ]

    @Test("accepts every persisted valid manifest")
    func acceptsValidManifests() throws {
        let validRoot = repositoryRoot.appending(path: "fixtures/vault-v1/valid")
        let cases = try FileManager.default.contentsOfDirectory(
            at: validRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for caseURL in cases.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = caseURL.appending(path: "vault.yaml")
            let manifest = try VaultManifestValidator.validate(
                data: Data(contentsOf: manifestURL),
                source: manifestURL.path
            )
            #expect(manifest.schema == "openpep/vault@1")
            #expect(manifest.protocolVersion == "1.0")
        }
    }

    @Test("rejects persisted invalid manifests with the declared issue")
    func rejectsInvalidManifests() throws {
        for caseName in invalidManifestCases {
            let caseURL = repositoryRoot.appending(path: "fixtures/vault-v1/invalid/\(caseName)")
            let expected = try JSONDecoder().decode(
                FixtureExpectation.self,
                from: Data(contentsOf: caseURL.appending(path: "expectation.json"))
            )
            do {
                _ = try VaultManifestValidator.validate(
                    data: Data(contentsOf: caseURL.appending(path: "vault.yaml")),
                    source: caseName
                )
                Issue.record("\(caseName) deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == expected.rule, "regra divergente em \(caseName)")
                #expect(issue.path == expected.path, "caminho divergente em \(caseName)")
            }
        }
    }

    @Test("rejects byte and text encodings outside the protocol")
    func rejectsInvalidEncoding() throws {
        let valid = try Data(contentsOf: repositoryRoot.appending(
            path: "fixtures/vault-v1/valid/minimal/vault.yaml"
        ))
        let cases: [(Data, String)] = [
            (Data([0xef, 0xbb, 0xbf]) + valid, "yaml.bom"),
            (Data(repeating: 0x20, count: VaultManifestValidator.maximumBytes + 1), "yaml.maximum_size"),
            (Data([0xff, 0xfe]), "yaml.utf8"),
            (Data("schema:\r\n".utf8), "yaml.line_endings"),
            (Data("x_name: cafe\u{301}\n".utf8), "yaml.unicode_nfc"),
        ]

        for (data, expectedRule) in cases {
            do {
                _ = try VaultManifestValidator.validate(data: data)
                Issue.record("\(expectedRule) deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == expectedRule)
            }
        }
    }

    @Test("validates every persisted operations manifest")
    func validatesOperationsManifests() throws {
        let fixtureRoot = repositoryRoot.appending(path: "fixtures/operations-manifest-v1")
        let validURL = fixtureRoot.appending(path: "valid/empty/manifest.yaml")
        let valid = try VaultManifestValidator.validateOperations(
            data: Data(contentsOf: validURL),
            source: validURL.path
        )
        #expect(valid.state == "empty")

        for caseName in invalidOperationsManifestCases {
            let caseURL = fixtureRoot.appending(path: "invalid/\(caseName)")
            let expected = try JSONDecoder().decode(
                FixtureExpectation.self,
                from: Data(contentsOf: caseURL.appending(path: "expectation.json"))
            )
            do {
                _ = try VaultManifestValidator.validateOperations(
                    data: Data(contentsOf: caseURL.appending(path: "manifest.yaml")),
                    source: caseName
                )
                Issue.record("\(caseName) deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == expected.rule, "regra divergente em \(caseName)")
                #expect(issue.path == expected.path, "caminho divergente em \(caseName)")
            }
        }
    }

    @Test("creates and opens the declared synthetic empty vault")
    func createsSyntheticVault() throws {
        try withTemporaryDirectory { parent in
            let identity = VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            )
            let createdAt = try #require(
                ISO8601DateFormatter().date(from: "2026-08-30T17:00:00Z")
            )
            let summary = try VaultCreator().create(
                in: parent,
                identity: identity,
                createdAt: createdAt
            )

            #expect(summary.writingAllowed)
            #expect(summary.manifest.vaultID == identity.vaultID)
            #expect(summary.operationsManifest?.vaultID == identity.vaultID)
            #expect(summary.operationsManifest?.state == "empty")
            let expectedTree = try JSONDecoder().decode(
                EmptyVaultTree.self,
                from: Data(contentsOf: repositoryRoot.appending(
                    path: "fixtures/vault-v1/valid/empty-vault/expected-tree.json"
                ))
            )
            for directory in expectedTree.directories {
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(
                    atPath: summary.url.appending(path: directory).path,
                    isDirectory: &isDirectory
                ))
                #expect(isDirectory.boolValue)
            }
            for file in expectedTree.files {
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(
                    atPath: summary.url.appending(path: file).path,
                    isDirectory: &isDirectory
                ))
                #expect(!isDirectory.boolValue)
            }
        }
    }

    @Test("validates the persisted raw asset sidecars")
    func validatesRawAssetSidecars() throws {
        let validURL = rawFixtureRoot.appending(path: "valid/synthetic-text/expected.meta.md")
        let valid = try VaultManifestValidator.validateRawAssetSidecar(
            data: Data(contentsOf: validURL),
            source: validURL.path
        )
        #expect(valid.assetID == "asset_0198f5d2-0000-7000-8000-000000000001")
        #expect(valid.patientID == "pt_0198f5c2-0000-7000-8000-000000000001")
        #expect(valid.sha256 == SyntheticRawFixtureContract.sha256)

        let generalURL = rawFixtureRoot.appending(path: "valid/general-text/expected.meta.md")
        let general = try VaultManifestValidator.validateRawAssetSidecar(
            data: Data(contentsOf: generalURL),
            source: generalURL.path
        )
        #expect(general.assetID == "asset_0198f5d2-0000-7000-8000-000000000077")
        #expect(general.encounterID == nil)
        #expect(general.quarantineState == "not_scanned")
        #expect(general.inspectionResult == "allowed_type_and_signature")

        for caseName in ["missing-sha256", "unknown-field"] {
            let caseURL = rawFixtureRoot.appending(path: "invalid/\(caseName)")
            let expected = try JSONDecoder().decode(
                FixtureExpectation.self,
                from: Data(contentsOf: caseURL.appending(path: "expectation.json"))
            )
            do {
                _ = try VaultManifestValidator.validateRawAssetSidecar(
                    data: Data(contentsOf: caseURL.appending(path: "asset.meta.md")),
                    source: caseName
                )
                Issue.record("\(caseName) deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == expected.rule)
                #expect(issue.path == expected.path)
            }
        }
    }

    @Test("creates the minimal opaque patient atomically")
    func createsSyntheticPatient() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
            let patient = try PatientCreator().create(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID)
            )
            let expectedTree = try JSONDecoder().decode(
                EmptyVaultTree.self,
                from: Data(contentsOf: rawFixtureRoot.appending(
                    path: "valid/synthetic-text/expected-patient-tree.json"
                ))
            )

            #expect(patient.patientID == patientID)
            #expect(patient.rawAssetCount == 0)
            for directory in expectedTree.directories {
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(
                    atPath: patient.url.appending(path: directory).path,
                    isDirectory: &isDirectory
                ))
                #expect(isDirectory.boolValue)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: patient.url.path).count == 4)

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.map(\.patientID) == [patientID])
            #expect(reopened.patients[0].rawAssetCount == patient.rawAssetCount)
        }
    }

    @Test("rejects unsafe patient IDs and removes its own failed temporary directory")
    func rejectsUnsafeOrPartialPatient() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            do {
                _ = try PatientCreator().create(
                    in: vault.url,
                    identity: PatientCreationIdentity(patientID: "../real-patient")
                )
                Issue.record("o caminho inseguro deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "patient.invalid_id")
            }

            let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
            let creator = PatientCreator(faultInjector: { step in
                if step == .directoriesCreated { throw SyntheticFailure() }
            })
            do {
                _ = try creator.create(
                    in: vault.url,
                    identity: PatientCreationIdentity(patientID: patientID)
                )
                Issue.record("a falha injetada deveria interromper a criação")
            } catch is SyntheticFailure {
                let patientsURL = vault.url.appending(path: "patients")
                #expect(!FileManager.default.fileExists(
                    atPath: patientsURL.appending(path: patientID).path
                ))
                #expect(try FileManager.default.contentsOfDirectory(atPath: patientsURL.path).isEmpty)
            }
        }
    }

    @Test("imports the exact synthetic fixture byte for byte with its sidecar")
    func importsSyntheticRawFixture() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let expectation = try rawFixtureExpectation()
            let importedAt = try #require(ISO8601DateFormatter().date(from: expectation.importedAt))
            let result = try RawAssetImporter().importFixture(
                from: rawSourceURL,
                into: patient,
                deviceID: expectation.deviceID,
                identity: RawAssetCreationIdentity(assetID: expectation.assetID),
                importedAt: importedAt
            )

            #expect(result.originalURL.path.hasSuffix(expectation.originalRelativePath))
            #expect(result.sidecarURL.path.hasSuffix(expectation.sidecarRelativePath))
            let importedBytes = try Data(contentsOf: result.originalURL)
            let sourceBytes = try Data(contentsOf: rawSourceURL)
            let sidecarBytes = try Data(contentsOf: result.sidecarURL)
            let expectedSidecarBytes = try Data(contentsOf: rawFixtureRoot.appending(
                path: "valid/synthetic-text/expected.meta.md"
            ))
            #expect(importedBytes == sourceBytes)
            #expect(sidecarBytes == expectedSidecarBytes)

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.count == 1)
            #expect(reopened.patients[0].rawAssetCount == 1)
            #expect(reopened.patients[0].rawAssets[0].assetID == expectation.assetID)
            #expect(reopened.patients[0].rawAssets[0].originalName == SyntheticRawFixtureContract.fileName)
            #expect(reopened.patients[0].rawAssets[0].sha256 == result.sha256)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: patient.url.appending(path: ".openpep").path
            ).isEmpty)
        }
    }

    @Test("recognizes the DOC-001 formats only when extension and signature agree")
    func recognizesGeneralDocumentFormats() throws {
        let samples: [(String, Data, String)] = [
            ("documento.pdf", Data("%PDF-1.7\n%%EOF\n".utf8), "application/pdf"),
            ("imagem.png", Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "image/png"),
            ("foto.jpg", Data([0xff, 0xd8, 0xff, 0xd9]), "image/jpeg"),
            ("foto.jpeg", Data([0xff, 0xd8, 0xff, 0xd9]), "image/jpeg"),
            ("nota.txt", Data("Conteúdo sintético UTF-8.\n".utf8), "text/plain"),
        ]

        for (name, data, expectedMediaType) in samples {
            let descriptor = try DocumentImportDescriptor.inspect(
                data: data,
                sourceURL: URL(fileURLWithPath: name)
            )
            #expect(descriptor.mediaType == expectedMediaType)
        }

        for (name, data) in [("incoerente.pdf", Data("não é um PDF".utf8)), ("binario.txt", Data([0, 1]))] {
            let descriptor = try DocumentImportDescriptor.inspect(data: data, sourceURL: URL(fileURLWithPath: name))
            #expect(descriptor.mediaType == "application/octet-stream")
            #expect(descriptor.inspectionResult == "opaque_file")
        }
        #expect(throws: VaultValidationIssue.self) {
            _ = try DocumentImportDescriptor.inspect(
                data: Data(count: DocumentImportDescriptor.maximumBytes + 1),
                sourceURL: URL(fileURLWithPath: "grande.png")
            )
        }
    }

    @Test("copies a general document into the vault and binds it to the selected encounter")
    func importsGeneralDocumentWithEncounterBinding() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let initialPatient = try createSyntheticPatient(in: vault)
            let encounterID = "enc_0198f5d1-0000-7000-8000-000000000077"
            _ = try ClinicalDraftCreator().create(
                in: initialPatient,
                identity: ClinicalDraftCreationIdentity(
                    encounterID: encounterID,
                    noteID: "note_0198f5d3-0000-7000-8000-000000000077",
                    syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000077"
                ),
                startedAt: Date(timeIntervalSince1970: 1_788_195_600)
            )
            let patient = try #require(VaultReader().open(vault.url).patients.first)
            let source = parent.appending(path: "laudo-sintetico.txt")
            let expectedBytes = Data("Documento clínico exclusivamente sintético.\n".utf8)
            try expectedBytes.write(to: source)
            let assetID = "asset_0198f5d2-0000-7000-8000-000000000077"

            let result = try GeneralDocumentImporter().importDocument(
                from: source,
                into: patient,
                encounterID: encounterID,
                deviceID: vault.manifest.deviceID,
                identity: RawAssetCreationIdentity(assetID: assetID),
                importedAt: Date(timeIntervalSince1970: 1_788_195_600)
            )
            try FileManager.default.removeItem(at: source)

            let reopened = try VaultReader().open(vault.url)
            let imported = try #require(reopened.patients.first?.rawAssets.first)
            #expect(imported.assetID == assetID)
            #expect(imported.encounterID == encounterID)
            #expect(imported.originalName == "laudo-sintetico.txt")
            #expect(imported.mediaType == "text/plain")
            #expect(imported.source == "file_import")
            #expect(imported.inspectionResult == "allowed_type_and_signature")
            #expect(try Data(contentsOf: result.originalURL) == expectedBytes)
            #expect(try Data(contentsOf: result.sidecarURL).isEmpty == false)
            #expect(
                try Data(contentsOf: RawAssetDocumentResolver().resolvePreview(
                    patientID: patient.patientID,
                    assetID: assetID,
                    in: vault.url
                )) == expectedBytes
            )
        }
    }

    @Test("rejects a foreign encounter and rolls back an interrupted document pair")
    func protectsGeneralDocumentBindingAndAtomicity() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let source = parent.appending(path: "nota-sintetica.txt")
            try Data("Nota sintética.\n".utf8).write(to: source)
            let absentEncounter = "enc_0198f5d1-0000-7000-8000-000000000088"

            do {
                _ = try GeneralDocumentImporter().importDocument(
                    from: source,
                    into: patient,
                    encounterID: absentEncounter,
                    deviceID: vault.manifest.deviceID,
                    identity: RawAssetCreationIdentity(
                        assetID: "asset_0198f5d2-0000-7000-8000-000000000088"
                    ),
                    importedAt: Date(timeIntervalSince1970: 1_788_195_600)
                )
                Issue.record("um atendimento ausente deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "document_import.encounter_binding")
            }

            let interruptedID = "asset_0198f5d2-0000-7000-8000-000000000089"
            let importer = GeneralDocumentImporter(faultInjector: { step in
                if step == .originalPublished { throw SyntheticFailure() }
            })
            #expect(throws: SyntheticFailure.self) {
                _ = try importer.importDocument(
                    from: source,
                    into: patient,
                    encounterID: nil,
                    deviceID: vault.manifest.deviceID,
                    identity: RawAssetCreationIdentity(assetID: interruptedID),
                    importedAt: Date(timeIntervalSince1970: 1_788_195_600)
                )
            }

            let rawURL = patient.url.appending(path: "raw")
            let descendants = FileManager.default.enumerator(atPath: rawURL.path)?
                .compactMap { $0 as? String } ?? []
            #expect(descendants.allSatisfy { !$0.contains(interruptedID) })
            #expect(try VaultReader().open(vault.url).patients.first?.rawAssets.isEmpty == true)
        }
    }

    @Test("does not replace a previously imported general document")
    func refusesGeneralDocumentReplacement() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let source = parent.appending(path: "documento-sintetico.pdf")
            try Data("%PDF-1.7\n% conteúdo sintético\n%%EOF\n".utf8).write(to: source)
            let identity = RawAssetCreationIdentity(
                assetID: "asset_0198f5d2-0000-7000-8000-000000000090"
            )
            let first = try GeneralDocumentImporter().importDocument(
                from: source,
                into: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                identity: identity,
                importedAt: Date(timeIntervalSince1970: 1_788_195_600)
            )
            let preserved = try Data(contentsOf: first.originalURL)

            do {
                _ = try GeneralDocumentImporter().importDocument(
                    from: source,
                    into: patient,
                    encounterID: nil,
                    deviceID: vault.manifest.deviceID,
                    identity: identity,
                    importedAt: Date(timeIntervalSince1970: 1_788_195_600)
                )
                Issue.record("um destino existente deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "raw_asset.destination_exists")
                #expect(try Data(contentsOf: first.originalURL) == preserved)
            }
        }
    }

    @Test("does not follow a symlinked document year directory")
    func rejectsSymlinkedGeneralDocumentDirectory() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let source = parent.appending(path: "nota-sintetica.txt")
            try Data("Nota sintética.\n".utf8).write(to: source)
            let external = parent.appending(path: "destino-externo")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: patient.url.appending(path: "raw/2026"),
                withDestinationURL: external
            )

            do {
                _ = try GeneralDocumentImporter().importDocument(
                    from: source,
                    into: patient,
                    encounterID: nil,
                    deviceID: vault.manifest.deviceID,
                    identity: RawAssetCreationIdentity(
                        assetID: "asset_0198f5d2-0000-7000-8000-000000000091"
                    ),
                    importedAt: Date(timeIntervalSince1970: 1_788_195_600)
                )
                Issue.record("um diretório intermediário por link simbólico deveria falhar")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "filesystem.directory")
                #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
            }
        }
    }

    @Test("rejects modified fixture bytes before writing")
    func rejectsModifiedRawFixture() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let sourceDirectory = parent.appending(path: "modified-source")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            let source = sourceDirectory.appending(path: SyntheticRawFixtureContract.fileName)
            var modified = try Data(contentsOf: rawSourceURL)
            modified[modified.startIndex] = 0x58
            try modified.write(to: source)

            do {
                _ = try RawAssetImporter().importFixture(
                    from: source,
                    into: patient,
                    deviceID: vault.manifest.deviceID,
                    identity: RawAssetCreationIdentity(
                        assetID: "asset_0198f5d2-0000-7000-8000-000000000001"
                    ),
                    importedAt: Date(timeIntervalSince1970: 0)
                )
                Issue.record("os bytes adulterados deveriam ter sido recusados")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "raw_asset.fixture_mismatch")
                #expect(try FileManager.default.contentsOfDirectory(
                    atPath: patient.url.appending(path: "raw").path
                ).isEmpty)
            }
        }
    }

    @Test("does not overwrite an asset and rolls back an interrupted pair")
    func refusesOverwriteAndRollsBackPair() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let expectation = try rawFixtureExpectation()
            let importedAt = try #require(ISO8601DateFormatter().date(from: expectation.importedAt))
            let identity = RawAssetCreationIdentity(assetID: expectation.assetID)
            let first = try RawAssetImporter().importFixture(
                from: rawSourceURL,
                into: patient,
                deviceID: expectation.deviceID,
                identity: identity,
                importedAt: importedAt
            )
            let originalBytes = try Data(contentsOf: first.originalURL)

            do {
                _ = try RawAssetImporter().importFixture(
                    from: rawSourceURL,
                    into: patient,
                    deviceID: expectation.deviceID,
                    identity: identity,
                    importedAt: importedAt
                )
                Issue.record("o destino existente deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "raw_asset.destination_exists")
                #expect(try Data(contentsOf: first.originalURL) == originalBytes)
            }

            let interruptedID = "asset_0198f5d2-0000-7000-8000-000000000002"
            let importer = RawAssetImporter(faultInjector: { step in
                if step == .originalPublished { throw SyntheticFailure() }
            })
            do {
                _ = try importer.importFixture(
                    from: rawSourceURL,
                    into: patient,
                    deviceID: expectation.deviceID,
                    identity: RawAssetCreationIdentity(assetID: interruptedID),
                    importedAt: importedAt
                )
                Issue.record("a falha injetada deveria interromper a publicação")
            } catch is SyntheticFailure {
                let monthURL = patient.url.appending(path: "raw/2026/08")
                #expect(!FileManager.default.fileExists(
                    atPath: monthURL.appending(path: "\(interruptedID).txt").path
                ))
                #expect(!FileManager.default.fileExists(
                    atPath: monthURL.appending(path: "\(interruptedID).meta.md").path
                ))
            }
        }
    }

    @Test("isolates the patient after an imported original is altered")
    func isolatesTamperedRawAsset() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let patient = try createSyntheticPatient(in: vault)
            let expectation = try rawFixtureExpectation()
            let importedAt = try #require(ISO8601DateFormatter().date(from: expectation.importedAt))
            let result = try RawAssetImporter().importFixture(
                from: rawSourceURL,
                into: patient,
                deviceID: expectation.deviceID,
                identity: RawAssetCreationIdentity(assetID: expectation.assetID),
                importedAt: importedAt
            )
            try Data("altered synthetic bytes\n".utf8).write(to: result.originalURL, options: [.atomic])

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.isEmpty)
            #expect(reopened.unavailablePatients.map(\.patientID) == [patient.patientID])
            #expect(reopened.statusMessage.contains("1 indisponível"))
        }
    }

    @Test("opens a legacy empty vault without silently migrating it")
    func opensLegacyVaultReadOnly() throws {
        try withTemporaryDirectory { parent in
            let created = try createSyntheticVault(in: parent)
            let operationsURL = created.url.appending(path: "operations/manifest.yaml")
            try FileManager.default.removeItem(at: operationsURL)

            let reopened = try VaultReader().open(created.url)
            #expect(reopened.operationsManifest == nil)
            #expect(!reopened.writingAllowed)
            #expect(!FileManager.default.fileExists(atPath: operationsURL.path))
        }
    }

    @Test("rejects an operations manifest bound to another vault")
    func rejectsMismatchedOperationsManifest() throws {
        try withTemporaryDirectory { parent in
            let created = try createSyntheticVault(in: parent)
            let operationsURL = created.url.appending(path: "operations/manifest.yaml")
            let mismatched = """
            schema: openpep/operations-manifest@1
            vault_id: vlt_0198f5c0-7f36-7b65-9f31-11a0d536a220
            state: empty
            """ + "\n"
            try Data(mismatched.utf8).write(to: operationsURL, options: [.atomic])

            do {
                _ = try VaultReader().open(created.url)
                Issue.record("o vault_id divergente deveria ter sido recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "operations.vault_id_mismatch")
                #expect(issue.path == "/vault_id")
            }
        }
    }

    @Test("does not publish a partial destination after a failure")
    func creationFailureIsAtomic() throws {
        try withTemporaryDirectory { parent in
            let creator = VaultCreator(faultInjector: { step in
                if step == .manifestWritten { throw SyntheticFailure() }
            })
            do {
                _ = try creator.create(
                    in: parent,
                    identity: VaultCreationIdentity(
                        vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                        deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
                    ),
                    createdAt: Date(timeIntervalSince1970: 0)
                )
                Issue.record("a falha injetada deveria interromper a criação")
            } catch is SyntheticFailure {
                #expect(!FileManager.default.fileExists(
                    atPath: parent.appending(path: "OpenPEP-Vault").path
                ))
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
                    .filter { $0.hasPrefix(".openpep-create-") }
                #expect(leftovers.isEmpty)
            }
        }
    }

    @Test("keeps the vault usable when an invalid patient entry is isolated")
    func isolatesInvalidPatientEntry() throws {
        try withTemporaryDirectory { parent in
            let summary = try VaultCreator().create(
                in: parent,
                identity: VaultCreationIdentity(
                    vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                    deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
                ),
                createdAt: Date(timeIntervalSince1970: 0)
            )
            try FileManager.default.createDirectory(
                at: summary.url.appending(path: "patients/pt_synthetic"),
                withIntermediateDirectories: false
            )
            let reopened = try VaultReader().open(summary.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.isEmpty)
            #expect(reopened.unavailablePatients.count == 1)
            #expect(reopened.unavailablePatients[0].patientID == nil)
        }
    }

    @Test("matches the shared scoped-isolation fixture without rewriting bytes")
    func matchesScopedIsolationFixture() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let fixtureRoot = repositoryRoot.appending(
                path: "fixtures/vault-directory-v1/scoped-isolation"
            )
            let expectation = try JSONDecoder().decode(
                VaultDirectoryExpectation.self,
                from: Data(contentsOf: fixtureRoot.appending(path: "expectation.json"))
            )
            for patientID in expectation.validPatients {
                _ = try PatientCreator().create(
                    in: vault.url,
                    identity: PatientCreationIdentity(patientID: patientID)
                )
            }
            for patientID in expectation.unavailablePatients {
                let root = vault.url.appending(path: "patients/\(patientID)")
                for directory in [".openpep", "content", "raw"] {
                    try FileManager.default.createDirectory(
                        at: root.appending(path: directory),
                        withIntermediateDirectories: true
                    )
                }
            }
            let unmanagedSource = fixtureRoot.appending(path: "notes-for-user.txt")
            let unmanagedDestination = vault.url.appending(path: "notes-for-user.txt")
            try FileManager.default.copyItem(at: unmanagedSource, to: unmanagedDestination)
            try FileManager.default.removeItem(at: vault.url.appending(path: "indexes"))
            let manifestURL = vault.url.appending(path: "vault.yaml")
            let manifestBefore = try Data(contentsOf: manifestURL)
            let unmanagedBefore = try Data(contentsOf: unmanagedDestination)

            let reopened = try VaultReader().open(vault.url)

            #expect(reopened.writingAllowed)
            #expect(reopened.patients.map(\.patientID) == expectation.validPatients)
            #expect(
                reopened.unavailablePatients.compactMap(\.patientID)
                    == expectation.unavailablePatients
            )
            #expect(reopened.unmanagedPaths == expectation.unmanagedPaths)
            #expect(try Data(contentsOf: manifestURL) == manifestBefore)
            #expect(try Data(contentsOf: unmanagedDestination) == unmanagedBefore)
        }
    }

    @Test("does not follow a symlinked root manifest")
    func rejectsSymlinkedRootManifest() throws {
        try withTemporaryDirectory { parent in
            let vault = try createSyntheticVault(in: parent)
            let manifestURL = vault.url.appending(path: "vault.yaml")
            let externalURL = parent.appending(path: "external-vault.yaml")
            try FileManager.default.moveItem(at: manifestURL, to: externalURL)
            try FileManager.default.createSymbolicLink(
                at: manifestURL,
                withDestinationURL: externalURL
            )

            do {
                _ = try VaultReader().open(vault.url)
                Issue.record("O manifesto por link simbólico deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "filesystem.regular_file")
                #expect(issue.path == "vault.yaml")
            }
        }
    }

    @Test("blocks writing when state empty disagrees with operational content")
    func blocksNonEmptyOperationsState() throws {
        try withTemporaryDirectory { parent in
            let created = try createSyntheticVault(in: parent)
            try Data("{}\n".utf8).write(
                to: created.url.appending(path: "operations/ledger/synthetic.ops.ndjson")
            )
            let reopened = try VaultReader().open(created.url)
            #expect(reopened.operationsManifest?.state == "empty")
            #expect(!reopened.writingAllowed)
        }
    }

    @Test("opens the synthetic cardiology demo with twenty bound patients")
    func opensCardiologyDemo() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let catalog = try #require(summary.demoCatalog)

        #expect(!summary.writingAllowed)
        #expect(summary.patients.count == 20)
        #expect(catalog.patients.count == 20)
        #expect(catalog.patients.filter { $0.nextAppointment != nil }.count == 11)
        #expect(summary.patients.reduce(0) { $0 + $1.rawAssets.count } == 60)
        #expect(summary.patients.allSatisfy { (2...5).contains($0.encounters.count) })
        #expect(summary.patients.allSatisfy { patient in
            catalog.profile(for: patient.patientID) != nil
                && patient.rawAssets.filter { $0.originalURL.pathExtension == "pdf" }.count == 2
                && patient.rawAssets.filter { $0.originalURL.pathExtension == "txt" }.count == 1
        })
    }

    @Test("resolves the selected PDF from the freshly validated patient and asset IDs")
    func resolvesSelectedPDF() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let patient = try #require(summary.patients.first)
        let pdf = try #require(patient.rawAssets.first {
            $0.mediaType == "application/pdf" && $0.originalURL.pathExtension == "pdf"
        })
        let originalBytes = try Data(contentsOf: pdf.originalURL)

        let resolved = try RawAssetDocumentResolver().resolvePreview(
            patientID: patient.patientID,
            assetID: pdf.assetID,
            in: cardiologyDemoRoot
        )

        #expect(resolved.standardizedFileURL == pdf.originalURL.standardizedFileURL)
        #expect(try Data(contentsOf: resolved) == originalBytes)
    }

    @Test("resolves a validated transcript for Quick Look")
    func resolvesTranscriptPreview() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let patient = try #require(summary.patients.first)
        let transcript = try #require(patient.rawAssets.first { $0.mediaType == "text/plain" })

        let resolved = try RawAssetDocumentResolver().resolvePreview(
            patientID: patient.patientID,
            assetID: transcript.assetID,
            in: cardiologyDemoRoot
        )

        #expect(resolved.standardizedFileURL == transcript.originalURL.standardizedFileURL)
    }

    @Test("blocks a PDF changed after the vault was opened")
    func blocksTamperedPDFPreview() throws {
        try withTemporaryDirectory { parent in
            let copied = parent.appending(path: "demo")
            try FileManager.default.copyItem(at: cardiologyDemoRoot, to: copied)
            let summary = try VaultReader().open(copied)
            let patient = try #require(summary.patients.first)
            let pdf = try #require(patient.rawAssets.first { $0.mediaType == "application/pdf" })
            var bytes = try Data(contentsOf: pdf.originalURL)
            bytes.append(0x20)
            try bytes.write(to: pdf.originalURL, options: [.atomic])

            do {
                _ = try RawAssetDocumentResolver().resolvePreview(
                    patientID: patient.patientID,
                    assetID: pdf.assetID,
                    in: copied
                )
                Issue.record("Um PDF alterado depois da abertura deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "demo_catalog.fixture_digest")
            }
        }
    }

    @Test("rejects a demo catalog that is not bound to validated raw assets")
    func rejectsUnboundDemoCatalog() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let catalogURL = cardiologyDemoRoot.appending(path: DemoCatalogReader.relativePath)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        var patients = try #require(object["patients"] as? [[String: Any]])
        var firstPatient = patients[0]
        var rawAssets = try #require(firstPatient["raw_assets"] as? [[String: Any]])
        rawAssets[0]["original_name"] = "documento-sintetico-divergente.pdf"
        firstPatient["raw_assets"] = rawAssets
        patients[0] = firstPatient
        object["patients"] = patients
        let modifiedCatalog = try JSONDecoder().decode(
            DemoCatalog.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        do {
            try DemoCatalogReader.validateBindings(modifiedCatalog, patients: summary.patients)
            Issue.record("O catálogo divergente deveria ter sido recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "demo_catalog.raw_binding")
        }
    }

    @Test("rejects a demo asset kind that disagrees with its validated sidecar")
    func rejectsUnboundDemoAssetKind() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let catalogURL = cardiologyDemoRoot.appending(path: DemoCatalogReader.relativePath)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        var patients = try #require(object["patients"] as? [[String: Any]])
        var firstPatient = patients[0]
        var rawAssets = try #require(firstPatient["raw_assets"] as? [[String: Any]])
        rawAssets[0]["kind"] = "transcript"
        firstPatient["raw_assets"] = rawAssets
        patients[0] = firstPatient
        object["patients"] = patients
        let modifiedCatalog = try JSONDecoder().decode(
            DemoCatalog.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        do {
            try DemoCatalogReader.validateBindings(modifiedCatalog, patients: summary.patients)
            Issue.record("O tipo divergente deveria ter sido recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "demo_catalog.raw_kind")
        }
    }

    @Test("requires the declared profile on generated demo sidecars")
    func rejectsDemoSidecarWithoutProfile() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let firstAsset = try #require(summary.patients.first?.rawAssets.first)
        let sidecarURL = firstAsset.originalURL.deletingLastPathComponent().appending(
            path: "\(firstAsset.assetID).meta.md"
        )
        let original = try String(contentsOf: sidecarURL, encoding: .utf8)
        let withoutProfile = original.replacingOccurrences(
            of: "x_fixture_profile: cardiology_demo_v1\n",
            with: ""
        )

        do {
            _ = try VaultManifestValidator.validateRawAssetSidecar(
                data: Data(withoutProfile.utf8),
                source: "missing-demo-profile"
            )
            Issue.record("O sidecar sem perfil demonstrativo deveria ter sido recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "raw_asset.profile")
        }
    }

    @Test("does not validate generated raw assets without the demo catalog")
    func isolatesGeneratedAssetsWithoutDemoCatalog() throws {
        try withTemporaryDirectory { parent in
            let copied = parent.appending(path: "demo")
            try FileManager.default.copyItem(at: cardiologyDemoRoot, to: copied)
            try FileManager.default.removeItem(
                at: copied.appending(path: DemoCatalogReader.relativePath)
            )

            let reopened = try VaultReader().open(copied)
            #expect(reopened.demoCatalog == nil)
            #expect(!reopened.writingAllowed)
            #expect(reopened.patients.isEmpty)
            #expect(reopened.unavailablePatients.count == 20)
            #expect(reopened.statusMessage.contains("Conteúdo operacional"))
        }
    }

    @Test("rejects coordinated changes to a demo PDF and its sidecar")
    func rejectsCoordinatedDemoTampering() throws {
        try withTemporaryDirectory { parent in
            let copied = parent.appending(path: "demo")
            try FileManager.default.copyItem(at: cardiologyDemoRoot, to: copied)
            let summary = try VaultReader().open(copied)
            let firstPDF = try #require(
                summary.patients.flatMap(\.rawAssets).first { $0.originalURL.pathExtension == "pdf" }
            )
            var data = try Data(contentsOf: firstPDF.originalURL)
            data.append(0x20)
            try data.write(to: firstPDF.originalURL, options: [.atomic])
            let sidecarURL = firstPDF.originalURL.deletingLastPathComponent().appending(
                path: "\(firstPDF.assetID).meta.md"
            )
            let sidecar = try String(contentsOf: sidecarURL, encoding: .utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let updatedSize = sidecar.replacingOccurrences(
                of: #"size_bytes: [0-9]+"#,
                with: "size_bytes: \(data.count)",
                options: .regularExpression
            )
            let updatedSidecar = updatedSize.replacingOccurrences(
                of: #"sha256: [0-9a-f]{64}"#,
                with: "sha256: \(digest)",
                options: .regularExpression
            )
            try Data(updatedSidecar.utf8).write(to: sidecarURL, options: [.atomic])

            do {
                _ = try VaultReader().open(copied)
                Issue.record("A árvore demonstrativa alterada deveria ter sido recusada")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "demo_catalog.fixture_digest")
            }
        }
    }

    @Test("builds a contextual encounter from only the selected patient")
    func buildsBoundEncounterContextWithoutWriting() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let catalog = try #require(summary.demoCatalog)
        let profile = try #require(catalog.patients.first { $0.consultations.count >= 3 })
        let patient = try #require(summary.patients.first { $0.patientID == profile.patientID })
        let selected = try #require(profile.consultations.max { $0.date < $1.date })
        let encounter = try #require(patient.encounters.first {
            $0.metadata.encounterID == selected.encounterID
        })
        let observedURLs = [encounter.url, encounter.draft.url] + patient.rawAssets.map(\.originalURL)
        let bytesBefore = try Dictionary(uniqueKeysWithValues: observedURLs.map {
            ($0.standardizedFileURL.path, try Data(contentsOf: $0))
        })

        let context = try EncounterContextBuilder.build(
            patient: patient,
            profile: profile,
            encounterID: selected.encounterID
        )

        #expect(context.patientID == patient.patientID)
        #expect(context.activeProblems == profile.activeProblems)
        #expect(context.exams.count == 2)
        #expect(Set(context.exams.map(\.kind)) == ["laboratory", "imaging"])
        #expect(context.exams.map(\.importedAt) == context.exams.map(\.importedAt).sorted(by: >))
        let previous = try #require(context.previousConsultation)
        #expect(previous.date < selected.date)
        let bytesAfter = try Dictionary(uniqueKeysWithValues: observedURLs.map {
            ($0.standardizedFileURL.path, try Data(contentsOf: $0))
        })
        #expect(bytesAfter == bytesBefore)
    }

    @Test("rejects contextual data from another patient")
    func rejectsCrossPatientEncounterContext() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let catalog = try #require(summary.demoCatalog)
        let patient = try #require(summary.patients.first)
        let encounter = try #require(patient.encounters.first)
        let otherProfile = try #require(catalog.patients.first {
            $0.patientID != patient.patientID
        })

        do {
            _ = try EncounterContextBuilder.build(
                patient: patient,
                profile: otherProfile,
                encounterID: encounter.metadata.encounterID
            )
            Issue.record("O contexto de outro paciente deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "encounter_context.patient_binding")
        }
    }

    @Test("rejects an encounter outside the selected patient")
    func rejectsCrossPatientEncounterSelection() throws {
        let summary = try VaultReader().open(cardiologyDemoRoot)
        let catalog = try #require(summary.demoCatalog)
        let patient = try #require(summary.patients.first)
        let profile = try #require(catalog.profile(for: patient.patientID))
        let otherEncounter = try #require(summary.patients.dropFirst().first?.encounters.first)

        do {
            _ = try EncounterContextBuilder.build(
                patient: patient,
                profile: profile,
                encounterID: otherEncounter.metadata.encounterID
            )
            Issue.record("O atendimento de outro paciente deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "encounter_context.encounter_binding")
        }
    }

    @Test("inserts the optional clinical outline without replacing existing text")
    func insertsOptionalClinicalDraftTemplate() {
        let original = "Evolução sintética já registrada.\n"

        let inserted = OptionalClinicalDraftTemplate.inserting(into: original)

        #expect(inserted.hasPrefix(original))
        #expect(inserted.contains("## Motivo do atendimento"))
        #expect(inserted.contains("## Avaliação"))
        #expect(OptionalClinicalDraftTemplate.inserting(into: inserted) == inserted)
    }

    @Test("CryptoKit verifies the golden ES256 fixture and rejects the altered signature")
    func verifiesES256FixtureWithCryptoKit() throws {
        let goldenRoot = repositoryRoot.appending(path: "fixtures/clinical-ledger-v1/golden/two-events")
        let registry = try JSONDecoder().decode(
            SigningKeyRegistry.self,
            from: Data(contentsOf: goldenRoot.appending(path: "signing-keys.json"))
        )
        let goldenEvent = try firstEvent(at: goldenRoot.appending(path: "ledger.ndjson"))
        let alteredEvent = try firstEvent(at: repositoryRoot.appending(
            path: "fixtures/clinical-ledger-v1/invalid/tampered-signature/ledger.ndjson"
        ))

        let publicKeyData = try base64URL(registry.keys[0].publicKeyX963)
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        let eventHash = try hexadecimal(goldenEvent.eventHash)
        let goldenSignature = try P256.Signing.ECDSASignature(
            rawRepresentation: base64URL(goldenEvent.signature)
        )
        let alteredSignature = try P256.Signing.ECDSASignature(
            rawRepresentation: base64URL(alteredEvent.signature)
        )

        #expect(publicKeyData.count == 65)
        #expect(goldenSignature.rawRepresentation.count == 64)
        #expect(eventHash.count == 32)
        #expect(publicKey.isValidSignature(goldenSignature, for: eventHash))
        #expect(!publicKey.isValidSignature(alteredSignature, for: eventHash))
    }

    @Test("stores only a safe relative path beside the vault bookmark")
    func derivesRelativeVaultPath() throws {
        let parent = URL(fileURLWithPath: "/tmp/openpep-bookmark-parent", isDirectory: true)
        let nested = parent.appending(path: "OpenPEP-Vault", directoryHint: .isDirectory)
        let outside = URL(fileURLWithPath: "/tmp/another-vault", isDirectory: true)

        #expect(try VaultBookmarkStore.relativeVaultPath(
            authorizationURL: parent,
            vaultURL: parent
        ) == "")
        #expect(try VaultBookmarkStore.relativeVaultPath(
            authorizationURL: parent,
            vaultURL: nested
        ) == "OpenPEP-Vault")
        #expect(throws: VaultValidationIssue.self) {
            try VaultBookmarkStore.relativeVaultPath(
                authorizationURL: parent,
                vaultURL: outside
            )
        }
    }

    @Test("round-trips and clears the last-vault bookmark")
    func roundTripsVaultBookmark() throws {
        let suiteName = "org.openpep.tests.bookmark.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try withTemporaryDirectory { parent in
            let vaultURL = parent.appending(path: "OpenPEP-Vault", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: false)
            let store = VaultBookmarkStore(defaults: defaults)

            try store.save(authorizationURL: parent, vaultURL: vaultURL)
            let resolvedReference = try store.resolve()
            let resolved = try #require(resolvedReference)
            #expect(resolved.authorizationURL.standardizedFileURL == parent.standardizedFileURL)
            #expect(resolved.vaultURL.standardizedFileURL == vaultURL.standardizedFileURL)

            store.clear()
            #expect(try store.resolve() == nil)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var rawFixtureRoot: URL {
        repositoryRoot.appending(path: "fixtures/raw-asset-v1")
    }

    private var rawSourceURL: URL {
        rawFixtureRoot.appending(path: "valid/synthetic-text/openpep-synthetic-raw.txt")
    }

    private var cardiologyDemoRoot: URL {
        repositoryRoot.appending(path: "fixtures/demo-cardiology-v1/vault")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-mac-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func createSyntheticVault(in parent: URL) throws -> VaultSummary {
        try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func createSyntheticPatient(in vault: VaultSummary) throws -> PatientSummary {
        try PatientCreator().create(
            in: vault.url,
            identity: PatientCreationIdentity(
                patientID: "pt_0198f5c2-0000-7000-8000-000000000001"
            )
        )
    }

    private func rawFixtureExpectation() throws -> RawFixtureExpectation {
        try JSONDecoder().decode(
            RawFixtureExpectation.self,
            from: Data(contentsOf: rawFixtureRoot.appending(
                path: "valid/synthetic-text/expectation.json"
            ))
        )
    }

    private func firstEvent(at url: URL) throws -> StoredClinicalEvent {
        let data = try Data(contentsOf: url)
        let firstLine = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
        return try JSONDecoder().decode(StoredClinicalEvent.self, from: Data(firstLine.utf8))
    }

    private func base64URL(_ value: String) throws -> Data {
        let normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return try #require(Data(base64Encoded: padded))
    }

    private func hexadecimal(_ value: String) throws -> Data {
        guard value.count.isMultiple(of: 2) else { throw SyntheticFailure() }
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { throw SyntheticFailure() }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

private struct FixtureExpectation: Decodable {
    let rule: String
    let path: String
}

private struct EmptyVaultTree: Decodable {
    let directories: [String]
    let files: [String]
}

private struct VaultDirectoryExpectation: Decodable {
    let validPatients: [String]
    let unavailablePatients: [String]
    let unmanagedPaths: [String]

    enum CodingKeys: String, CodingKey {
        case validPatients = "valid_patients"
        case unavailablePatients = "unavailable_patients"
        case unmanagedPaths = "unmanaged_paths"
    }
}

private struct SigningKeyRegistry: Decodable {
    let keys: [SigningKey]
}

private struct SigningKey: Decodable {
    let publicKeyX963: String

    enum CodingKeys: String, CodingKey {
        case publicKeyX963 = "public_key_x963"
    }
}

private struct StoredClinicalEvent: Decodable {
    let eventHash: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case eventHash = "event_hash"
        case signature
    }
}

private struct RawFixtureExpectation: Decodable {
    let assetID: String
    let deviceID: String
    let importedAt: String
    let originalRelativePath: String
    let sidecarRelativePath: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case deviceID = "device_id"
        case importedAt = "imported_at"
        case originalRelativePath = "original_relative_path"
        case sidecarRelativePath = "sidecar_relative_path"
    }
}

private struct SyntheticFailure: Error {}
