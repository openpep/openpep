#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build a deterministic lookup table from the pinned, licensed IPS RF2 snapshot."""
import argparse
import csv
import hashlib
import io
from pathlib import Path
import zipfile

SHA256 = '6b21353df041e421de151d17871552cd74cc25a01c3e9ba002fb0422ab085387'

def build(archive, output):
    data = Path(archive).read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Unexpected IPS release: review the version before importing.')
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        def rows(prefix):
            name, = [n for n in z.namelist() if n.rsplit('/', 1)[-1].startswith(prefix)]
            return list(csv.DictReader(io.StringIO(z.read(name).decode('utf-8-sig')), delimiter='\t'))
        concepts = {r['id'] for r in rows('sct2_Concept_') if r['active'] == '1'}
        descriptions = rows('sct2_Description_')
        assert len(concepts) == 19697 and len(descriptions) == 60114
        records = sorted((r['conceptId'], r['typeId'], r['term']) for r in descriptions
                         if r['active'] == '1' and r['languageCode'] == 'en')
        assert all(r[0] in concepts and '\t' not in r[2] and '\n' not in r[2] for r in records)
        payload = 'conceptId\ttypeId\tterm\n' + ''.join('\t'.join(r) + '\n' for r in records)
        Path(output).write_text(payload, encoding='utf-8')
        print(f'{len(concepts)} concepts; {len(records)} descriptions; sha256={hashlib.sha256(payload.encode()).hexdigest()}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('output')
    args = parser.parse_args()
    build(args.archive, args.output)
