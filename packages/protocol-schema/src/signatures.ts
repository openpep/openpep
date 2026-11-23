// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

import { createPublicKey, verify as verifySignature } from "node:crypto";
import { validationError } from "./errors.js";

export const es256SignatureBytes = 64;
export const p256PublicKeyX963Bytes = 65;
const p256Order = BigInt(
  "0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
);
const p256HalfOrder = p256Order / 2n;

export function validateP256PublicKeyX963(
  encodedKey: string,
  source = "<signing-key>",
  path = "/public_key_x963",
): void {
  createP256PublicKey(encodedKey, source, path);
}

export function verifyEs256EventHashSignature(
  eventHash: string,
  encodedSignature: string,
  encodedPublicKey: string,
  source = "<clinical-event>",
  path = "/signature",
): void {
  if (!/^[0-9a-f]{64}$/.test(eventHash)) {
    throw validationError(
      source,
      "/event_hash",
      "ledger.event_hash_encoding",
      "event_hash deve conter 32 bytes em hexadecimal minúsculo",
    );
  }
  const signature = decodeBase64Url(
    encodedSignature,
    es256SignatureBytes,
    source,
    path,
    "ledger.signature_encoding",
    "signature deve conter 64 bytes IEEE P1363 em base64url sem padding",
  );
  if (normalizeEs256Signature(encodedSignature, source, path) !==
      encodedSignature) {
    throw validationError(
      source,
      path,
      "ledger.signature_non_canonical",
      "a assinatura ES256 deve usar a forma low-S canônica",
    );
  }
  const publicKey = createP256PublicKey(
    encodedPublicKey,
    source,
    path,
  );

  const valid = verifySignature(
    "sha256",
    Buffer.from(eventHash, "hex"),
    { key: publicKey, dsaEncoding: "ieee-p1363" },
    signature,
  );
  if (!valid) {
    throw validationError(
      source,
      path,
      "ledger.signature_invalid",
      "a assinatura ES256 não corresponde ao hash e à chave registrados",
    );
  }
}

export function normalizeEs256Signature(
  encodedSignature: string,
  source = "<clinical-event>",
  path = "/signature",
): string {
  const signature = decodeBase64Url(
    encodedSignature,
    es256SignatureBytes,
    source,
    path,
    "ledger.signature_encoding",
    "signature deve conter 64 bytes IEEE P1363 em base64url sem padding",
  );
  const r = BigInt(`0x${signature.subarray(0, 32).toString("hex")}`);
  const s = BigInt(`0x${signature.subarray(32).toString("hex")}`);
  if (r === 0n || r >= p256Order || s === 0n || s >= p256Order) {
    throw validationError(
      source,
      path,
      "ledger.signature_encoding",
      "os componentes R e S devem pertencer ao intervalo P-256",
    );
  }
  if (s <= p256HalfOrder) {
    return encodedSignature;
  }

  const normalizedS = (p256Order - s).toString(16).padStart(64, "0");
  Buffer.from(normalizedS, "hex").copy(signature, 32);
  return signature.toString("base64url");
}

function createP256PublicKey(
  encodedKey: string,
  source: string,
  path: string,
) {
  const bytes = decodeBase64Url(
    encodedKey,
    p256PublicKeyX963Bytes,
    source,
    path,
    "ledger.public_key_encoding",
    "public_key_x963 deve conter 65 bytes ANSI X9.63 em base64url sem padding",
  );
  if (bytes[0] !== 0x04) {
    throw validationError(
      source,
      path,
      "ledger.public_key_encoding",
      "a chave pública P-256 deve usar a forma X9.63 não comprimida",
    );
  }

  try {
    return createPublicKey({
      key: {
        kty: "EC",
        crv: "P-256",
        x: bytes.subarray(1, 33).toString("base64url"),
        y: bytes.subarray(33, 65).toString("base64url"),
      },
      format: "jwk",
    });
  } catch {
    throw validationError(
      source,
      path,
      "ledger.public_key_invalid",
      "public_key_x963 não representa um ponto válido da curva P-256",
    );
  }
}

function decodeBase64Url(
  value: string,
  expectedBytes: number,
  source: string,
  path: string,
  rule: string,
  message: string,
): Buffer {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw validationError(source, path, rule, message);
  }
  const bytes = Buffer.from(value, "base64url");
  if (bytes.length !== expectedBytes || bytes.toString("base64url") !== value) {
    throw validationError(source, path, rule, message);
  }
  return bytes;
}
