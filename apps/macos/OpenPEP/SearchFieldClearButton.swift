// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

extension View {
    func searchClearButton(_ text: Binding<String>) -> some View {
        self.padding(.trailing, text.wrappedValue.isEmpty ? 0 : 26)
            .overlay(alignment: .trailing) {
                if !text.wrappedValue.isEmpty {
                    Button { text.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.trailing, 5)
                    .accessibilityLabel("Limpar busca").help("Limpar busca")
                }
            }
    }
}
