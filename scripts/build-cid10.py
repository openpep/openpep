#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors
# SPDX-License-Identifier: Apache-2.0
"""Normalize the pinned official DATASUS V2008 ZIP; never fetch data at runtime."""
import argparse
import csv
import hashlib
import io
from pathlib import Path
import zipfile

ZIP_SHA256 = "84f23809275575f751255048064bbb244b0de33fd5987ab98df0f98e5f5d2c95"
TSV_SHA256 = "a5a8ae4dfd02186e90bebb1387bab5bff9f6209b37c111e8a69a866fa7b924f1"


def convert(source: bytes) -> bytes:
    if hashlib.sha256(source).hexdigest() != ZIP_SHA256:
        raise ValueError("ZIP diferente da fonte DATASUS V2008 registrada; revise a procedência.")
    descriptions = {}
    with zipfile.ZipFile(io.BytesIO(source)) as archive:
        for name, field, expected_rows in [
            ("CID-10-CATEGORIAS.CSV", "CAT", 2045),
            ("CID-10-SUBCATEGORIAS.CSV", "SUBCAT", 12451),
        ]:
            rows = list(csv.DictReader(io.StringIO(archive.read(name).decode("iso-8859-1")), delimiter=";"))
            if len(rows) != expected_rows:
                raise ValueError(f"Contagem inesperada: {name}")
            for row in rows:
                code, description = row[field].strip(), row["DESCRICAO"].strip()
                if len(code) == 4:
                    code = code[:3] + "." + code[3:]
                if code in descriptions and descriptions[code] != description:
                    raise ValueError(f"Descrições conflitantes para {code}")
                descriptions[code] = description
    if len(descriptions) != 14233:
        raise ValueError("Contagem inesperada de códigos únicos")
    output = "".join(f"{code}\t{description}\n" for code, description in sorted(descriptions.items())).encode("utf-8")
    if hashlib.sha256(output).hexdigest() != TSV_SHA256:
        raise ValueError("Catálogo normalizado diverge do recurso revisado")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    output = convert(args.zip.read_bytes())
    args.output.write_bytes(output)
    print(f"14.233 códigos; SHA-256 {TSV_SHA256}")


if __name__ == "__main__":
    main()
