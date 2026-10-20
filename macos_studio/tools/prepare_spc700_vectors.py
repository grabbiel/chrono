#!/usr/bin/env python3
"""Reproduce the bundled sample from the pinned SingleStepTests checkout.

No downloads or updates are implicit. Pass the checkout's spc700/v1 directory.
Use --check to validate the sample without changing it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PIN = 'bb11756436da8fd16cce86aef63dc6725f48836f'
INDICES = [0, 1, 127, 255, 511, 767, 998, 999]
PACKAGE = Path(__file__).resolve().parents[1]
DEST = PACKAGE / 'Tests/ChronoForgeCoreTests/Resources/SPC700'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    corpus = args.corpus.resolve()
    commit = subprocess.check_output(['git', '-C', str(corpus), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != PIN:
        raise SystemExit(f'Expected corpus commit {PIN}, found {commit}')
    # HEAD alone does not detect modified corpus bytes.
    if subprocess.check_output(['git', '-C', str(corpus), 'status', '--porcelain', '--', '.'], text=True).strip():
        raise SystemExit('Corpus has local changes; restore or use a clean pinned checkout')
    cases = []
    for op in range(256):
        rows = json.loads((corpus / f'{op:02x}.json').read_text())
        if len(rows) != 1000:
            raise SystemExit(f'Opcode {op:02x}: expected 1000 cases')
        cases.extend(rows[i] for i in INDICES)
    data = (json.dumps(cases, separators=(',', ':')) + '\n').encode()
    metadata = {
        'repository': 'https://github.com/SingleStepTests/ProcessorTests',
        'commit': PIN, 'path': 'spc700/v1', 'generator': 'David Schneider / JSMoo',
        'case_indices_per_opcode': INDICES, 'cases': len(cases),
        'sha256': hashlib.sha256(data).hexdigest(),
    }
    provenance = (json.dumps(metadata, indent=2) + '\n').encode()
    for name, content in [('vectors.json', data), ('provenance.json', provenance)]:
        target = DEST / name
        if args.check:
            if target.read_bytes() != content:
                raise SystemExit(f'{target} differs from pinned corpus')
        else:
            DEST.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
    print(f'{len(cases)} bundled cases reproduce the pinned corpus')


if __name__ == '__main__':
    main()
