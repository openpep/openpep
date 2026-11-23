// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Security
import CryptoKit

struct LocalPDFSignaturePreparation: Sendable {
    let pdf: Data
    let byteRange: [Int]
    init(pdf: Data, byteRange: [Int]) throws {
        guard pdf.count <= 25 * 1024 * 1024, byteRange.count == 4, byteRange[0] == 0,
              byteRange[1] > 0, byteRange[1] < pdf.count - 2,
              byteRange[2] > byteRange[1] + 2, byteRange[2] <= pdf.count,
              byteRange[3] == pdf.count - byteRange[2],
              pdf[byteRange[1]] == 60, pdf[byteRange[2] - 1] == 62,
              pdf[(byteRange[1] + 1)..<(byteRange[2] - 1)].allSatisfy({ $0 == 48 }) else { throw LocalSignerError.invalidPDF }
        self.pdf = pdf; self.byteRange = byteRange
    }
    var content: Data { pdf.prefix(byteRange[1]) + pdf.suffix(byteRange[3]) }
    func inserting(_ cms: Data) throws -> Data {
        let capacity = byteRange[2] - byteRange[1] - 2
        guard !cms.isEmpty, cms.count * 2 <= capacity else { throw LocalSignerError.invalidPDF }
        let hex = cms.map { String(format: "%02X", $0) }.joined().padding(toLength: capacity, withPad: "0", startingAt: 0)
        var result = pdf
        result.replaceSubrange((byteRange[1] + 1)..<(byteRange[2] - 1), with: Data(hex.utf8))
        guard result.count == pdf.count,
              result.prefix(byteRange[1]) + result.suffix(byteRange[3]) == content else { throw LocalSignerError.invalidPDF }
        return result
    }
}

/// Uses the identity exposed by the installed token. No private-key export, PIN storage or automatic retry.
/// CMS integrity is checked here; ICP-Brasil policy/revocation and sandbox homologation remain separate gates.
enum LocalPDFSigner {
    struct Identity: Identifiable, @unchecked Sendable {
        // Immutable Security references are passed to one worker for one operation.
        let reference: SecIdentity
        let certificate: Data
        let name: String
        var id: String { SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() }
    }
    static func acceptsToken(_ token: String) -> Bool {
        let extensionID = "br.com.valid.vidaas.connect.vidaasConnectToken"
        return token == extensionID || token.hasPrefix(extensionID + ":")
    }
    static func identities() throws -> [Identity] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw LocalSignerError.message("Não foi possível consultar os certificados. Abra o VIDaaS Connect e tente novamente.")
        }
        return identities.compactMap { identity in
            var key: SecKey?
            guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
                  let attrs = SecKeyCopyAttributes(key) as? [String: Any],
                  let token = attrs[kSecAttrTokenID as String] as? String,
                  acceptsToken(token) else { return nil }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            return Identity(reference: identity, certificate: SecCertificateCopyData(certificate) as Data,
                name: SecCertificateCopySubjectSummary(certificate) as String? ?? "Certificado local")
        }
    }
    static func sign(_ prepared: LocalPDFSignaturePreparation, with identity: Identity) throws -> Data {
        var encoder: CMSEncoder?
        try check(CMSEncoderCreate(&encoder))
        guard let encoder else { throw LocalSignerError.invalidPDF }
        try check(CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256))
        try check(CMSEncoderAddSigners(encoder, identity.reference))
        try check(CMSEncoderSetHasDetachedContent(encoder, true))
        try check(CMSEncoderSetCertificateChainMode(encoder, .chainWithRoot))
        let content = prepared.content
        try content.withUnsafeBytes { buffer in try check(CMSEncoderUpdateContent(encoder, buffer.baseAddress!, buffer.count)) }
        var encoded: CFData?
        try check(CMSEncoderCopyEncodedContent(encoder, &encoded))
        guard let encoded else { throw LocalSignerError.invalidPDF }
        let cms = encoded as Data
        try verify(cms: cms, content: content, certificate: identity.certificate)
        return try prepared.inserting(cms)
    }
    static func verify(cms: Data, content: Data, certificate: Data) throws {
        var decoder: CMSDecoder?
        try check(CMSDecoderCreate(&decoder))
        guard let decoder else { throw LocalSignerError.invalidPDF }
        try cms.withUnsafeBytes { buffer in try check(CMSDecoderUpdateMessage(decoder, buffer.baseAddress!, buffer.count)) }
        try check(CMSDecoderSetDetachedContent(decoder, content as CFData))
        try check(CMSDecoderFinalizeMessage(decoder))
        var count = 0
        try check(CMSDecoderGetNumSigners(decoder, &count))
        guard count == 1 else { throw LocalSignerError.invalidPDF }
        var actual: SecCertificate?
        try check(CMSDecoderCopySignerCert(decoder, 0, &actual))
        guard let actual, SecCertificateCopyData(actual) as Data == certificate else { throw LocalSignerError.invalidPDF }
        var status = CMSSignerStatus.unsigned
        try check(CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, nil, nil))
        guard status == .valid else { throw LocalSignerError.invalidPDF }
    }
    static func verifyPDF(_ pdf: Data, certificate: Data) throws {
        guard pdf.count <= 25 * 1024 * 1024, let text = String(data: pdf, encoding: .isoLatin1) else { throw LocalSignerError.invalidPDF }
        let regex = try NSRegularExpression(pattern: #"/ByteRange\s*\[\s*0\s+(\d+)\s+(\d+)\s+(\d+)\s*\]"#)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard matches.count == 1 else { throw LocalSignerError.invalidPDF }
        let ns = text as NSString
        let values = (1...3).compactMap { Int(ns.substring(with: matches[0].range(at: $0))) }
        guard values.count == 3 else { throw LocalSignerError.invalidPDF }
        let start = values[0], end = values[1], tail = values[2]
        guard start > 0, start < pdf.count - 2, end > start + 2, end <= pdf.count, tail == pdf.count - end,
              pdf[start] == 60, pdf[end - 1] == 62 else { throw LocalSignerError.invalidPDF }
        let hex = Array(pdf[(start + 1)..<(end - 1)])
        guard hex.count.isMultiple(of: 2) else { throw LocalSignerError.invalidPDF }
        var cms = Data()
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let value = UInt8(String(bytes: hex[index...index + 1], encoding: .ascii) ?? "", radix: 16) else { throw LocalSignerError.invalidPDF }
            cms.append(value)
        }
        // Security may emit BER with indefinite constructed lengths. Locate its exact
        // end before accepting the zero padding in the PDF signature placeholder.
        func elementEnd(_ start: Int, depth: Int) throws -> Int {
            guard depth < 32, start + 2 <= cms.count else { throw LocalSignerError.invalidPDF }
            let tag = cms[start]; var cursor = start + 1
            if tag & 0x1f == 0x1f {
                var count = 0
                while cursor < cms.count {
                    let byte = cms[cursor]; cursor += 1; count += 1
                    guard count <= 5 else { throw LocalSignerError.invalidPDF }
                    if byte & 0x80 == 0 { break }
                }
            }
            guard cursor < cms.count else { throw LocalSignerError.invalidPDF }
            let first = cms[cursor]; cursor += 1
            if first == 0x80 {
                guard tag & 0x20 != 0 else { throw LocalSignerError.invalidPDF }
                while cursor + 2 <= cms.count {
                    if cms[cursor] == 0 && cms[cursor + 1] == 0 { return cursor + 2 }
                    cursor = try elementEnd(cursor, depth: depth + 1)
                }
                throw LocalSignerError.invalidPDF
            }
            let count = first & 0x80 == 0 ? 0 : Int(first & 0x7f)
            guard count <= 4, cursor + count <= cms.count else { throw LocalSignerError.invalidPDF }
            var length = count == 0 ? Int(first) : 0
            for _ in 0..<count { length = length * 256 + Int(cms[cursor]); cursor += 1 }
            guard length <= cms.count - cursor else { throw LocalSignerError.invalidPDF }
            return cursor + length
        }
        guard cms.first == 0x30 else { throw LocalSignerError.invalidPDF }
        let total = try elementEnd(0, depth: 0)
        guard cms.suffix(from: total).allSatisfy({ $0 == 0 }) else { throw LocalSignerError.invalidPDF }
        try verify(cms: cms.prefix(total), content: pdf.prefix(start) + pdf.suffix(tail), certificate: certificate)
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw LocalSignerError.message(status == errSecUserCanceled ? "Assinatura cancelada. O documento não foi emitido." : "O certificado não concluiu a assinatura. Confira o VIDaaS Connect. Não houve nova tentativa automática.")
        }
    }
}

// JSON over stdio. No document paths, credential arguments or private-key export.
enum LocalSignerError: Error { case invalidPDF; case message(String) }
struct SignRequest: Decodable { let pdf: String; let range: [Int]; let identity: String }
func output(_ object: Any) throws {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}
func run() throws {
    guard CommandLine.arguments.count == 2 else { throw LocalSignerError.invalidPDF }
    switch CommandLine.arguments[1] {
    case "list":
        try output(LocalPDFSigner.identities().map { ["id": $0.id, "name": $0.name] })
    case "sign":
        var raw = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
            guard raw.count + chunk.count <= 36 * 1024 * 1024 else { throw LocalSignerError.invalidPDF }
            raw.append(chunk)
        }
        let request = try JSONDecoder().decode(SignRequest.self, from: raw)
        guard let pdf = Data(base64Encoded: request.pdf) else { throw LocalSignerError.invalidPDF }
        let prepared = try LocalPDFSignaturePreparation(pdf: pdf, byteRange: request.range)
        let identities = try LocalPDFSigner.identities().filter { $0.id == request.identity }
        guard identities.count == 1 else { throw LocalSignerError.message("Certificado VIDaaS indisponível.") }
        let signed = try LocalPDFSigner.sign(prepared, with: identities[0])
        try LocalPDFSigner.verifyPDF(signed, certificate: identities[0].certificate)
        try output(["pdf": signed.base64EncodedString()])
    case "self-test":
        guard LocalPDFSigner.acceptsToken("br.com.valid.vidaas.connect.vidaasConnectToken:synthetic"),
              !LocalPDFSigner.acceptsToken("other-token"),
              !LocalPDFSigner.acceptsToken("br.com.valid.vidaas.connect.vidaasConnectToken.other") else { throw LocalSignerError.invalidPDF }
        let prepared = try LocalPDFSignaturePreparation(pdf: Data("PDF<00000000>END".utf8), byteRange: [0, 3, 13, 3])
        let filled = try prepared.inserting(Data([1, 2]))
        guard String(data: filled, encoding: .utf8) == "PDF<01020000>END" else { throw LocalSignerError.invalidPDF }
        try output(["synthetic": true])
    default: throw LocalSignerError.invalidPDF
    }
}
do { try run() } catch {
    // Never echo certificate attributes, PDF content or operating-system error details.
    FileHandle.standardError.write(Data("VIDaaS local não concluiu a operação. Confira o Connect; não houve repetição automática.\n".utf8))
    exit(1)
}
