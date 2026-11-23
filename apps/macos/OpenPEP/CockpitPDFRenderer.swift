// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import WebKit

/// The original Cockpit RX PDF layout, bundled offline. No page or patient data is loaded remotely.
@MainActor final class CockpitPDFRenderer: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?
    private var ready = false
    private func prepare() async throws {
        if ready { return }
        guard web == nil else { throw CockpitError.message("Aguarde a preparação do PDF.") }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "OpenPEPCockpitOffline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#)
        if let rules { config.userContentController.add(rules) }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; web = view
        do {
            try await withCheckedThrowingContinuation { continuation in
                loaded = continuation
                view.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-eval'\"></head><body></body></html>", baseURL: nil)
            }
            let js = try String(contentsOf: resource("renderer", "js"), encoding: .utf8)
            _ = try await view.evaluateJavaScript(js)
            ready = true
        } catch { web = nil; throw error }
    }
    static func resource(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "CockpitPDF")
            ?? Bundle.main.url(forResource: name, withExtension: ext) else {
            throw CockpitError.message("Os modelos de receita não estão disponíveis nesta instalação.")
        }
        return url
    }
    private func resource(_ name: String, _ ext: String) throws -> URL { try Self.resource(name, ext) }
    func render(_ input: [String: Any]) async throws -> (pdf: Data, term: Data?, source: String) {
        try await prepare()
        var fonts: [String: String] = [:]
        for (key, weight) in [("regular",400),("medium",500),("semibold",600),("bold",700)] {
            fonts[key] = try Data(contentsOf: resource("inter-\(weight)-latin", "ttf")).base64EncodedString()
        }
        let value: Any?
        do {
            value = try await web!.callAsyncJavaScript("return await OpenPEPCockpitPDF.nativeRender(input, fonts)",
                arguments: ["input": input, "fonts": fonts], in: nil, contentWorld: .page)
        } catch {
            if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                throw CockpitError.message(message)
            }
            throw error
        }
        guard let result = value as? [String: Any], let encoded = result["pdf"] as? String,
              let pdf = Data(base64Encoded: encoded), let source = result["source"] as? String else { throw CockpitError.invalidPDF }
        return (pdf, (result["term"] as? String).flatMap { Data(base64Encoded: $0) }, source)
    }
    func prepareSignature(_ pdf: Data) async throws -> LocalPDFSignaturePreparation {
        try await prepare()
        let value = try await web!.callAsyncJavaScript("return await OpenPEPCockpitPDF.nativePrepare(pdf)",
            arguments: ["pdf": pdf.base64EncodedString()], in: nil, contentWorld: .page)
        guard let result = value as? [String: Any], let encoded = result["pdf"] as? String,
              let bytes = Data(base64Encoded: encoded), let range = result["range"] as? [Int] else { throw CockpitError.invalidPDF }
        return try LocalPDFSignaturePreparation(pdf: bytes, byteRange: range)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.resume(throwing: CockpitError.invalidPDF); loaded = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded?.resume(throwing: CockpitError.invalidPDF); loaded = nil }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loaded?.resume(throwing: CockpitError.invalidPDF); loaded = nil; web = nil; ready = false }
}

enum CockpitError: LocalizedError {
    case message(String), invalidPDF, invalidRegistry
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .invalidPDF: "Não foi possível preparar ou verificar o PDF. O documento não foi emitido."
        case .invalidRegistry: "O registro de números não pôde ser conferido. Nenhum número foi reutilizado."
        }
    }
}
