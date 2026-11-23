// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Combine
import SwiftUI

struct PatientWikiExcerptView: View {
    let patient: PatientSummary
    let authorizationURL: URL?
    let fallback: String?
    @State private var excerpt: String?
    @State private var refreshID = UUID()

    private var loadID: String { patient.url.standardizedFileURL.path + refreshID.uuidString }

    var body: some View {
        Group {
            if let visibleExcerpt, !visibleExcerpt.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(visibleExcerpt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .task(id: loadID) { await load() }
            } else {
                Color.clear.frame(height: 0)
                    .accessibilityHidden(true)
                    .task(id: loadID) { await load() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PatientClinicalChange.notification)
            .receive(on: RunLoop.main)) { change in
                guard PatientClinicalChange.matches(change, patientURL: patient.url) else { return }
                refreshID = UUID()
            }
    }

    private var visibleExcerpt: String? {
        (excerpt ?? fallback)?
            .replacingOccurrences(of: #"\s*\[F[0-9]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func load() async {
        let patient = patient
        let authorizationURL = authorizationURL
        excerpt = await Task.detached {
            let granted = authorizationURL?.startAccessingSecurityScopedResource() == true
            defer { if granted { authorizationURL?.stopAccessingSecurityScopedResource() } }
            return try? PatientWikiStore().load(for: patient).summary?.overview
        }.value
    }
}
