// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum PostalCodeLookup {
    static func mayAutofill(current: YAMLValue?, original: YAMLValue?, lastAutomatic: String?) -> Bool {
        guard current == original else { return false }
        guard let current else { return true }
        guard case let .string(value) = current else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value == lastAutomatic
    }

    static func fetch(_ cep: String) async throws -> [String: String] {
        guard cep.count == 8, cep.allSatisfy({ $0.isASCII && $0.isNumber }),
              let url = URL(string: "https://viacep.com.br/ws/\(cep)/json/") else {
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [String: String] {
        struct Address: Decodable {
            let cep: String
            let logradouro: String
            let bairro: String
            let localidade: String
            let uf: String
        }
        // Missing `cep` also rejects ViaCEP's {"erro": true} response.
        let value = try JSONDecoder().decode(Address.self, from: data)
        return ["street": value.logradouro, "district": value.bairro,
                "city": value.localidade, "state": value.uf]
    }
}
