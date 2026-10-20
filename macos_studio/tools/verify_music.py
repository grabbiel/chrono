#!/usr/bin/env python3
"""The Swift CLI's song sequences against the Python twin (re_workspace/tools/ct_spc_seq.py).

`chronoforge music verify-rom` renders every Audio_SongTable song to its
ct-song/1 listing and assembles it back; each song's data hash and listing
hash must equal those in re_workspace/manifests/spc_sequences.json, so both
implementations print the same listing text, byte for byte.
"""
import json
import subprocess
import sys
import tempfile
import hashlib
from pathlib import Path

package = Path(__file__).resolve().parents[1]
workspace = package.parent / 're_workspace'
cli = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else package / '.build/debug/chronoforge'
manifest = {s['song']: s for s in json.loads((workspace / 'manifests/spc_sequences.json').read_text())['songs']}
result = subprocess.run([str(cli), 'music', 'verify-rom', str(workspace / 'ct_clean.sfc')],
                        capture_output=True, text=True, timeout=600)
rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
if result.returncode != 0 or len(rows) != len(manifest):
    raise SystemExit(f'FAIL: music verify-rom\n{result.stdout[-2000:]}{result.stderr}')
for row in rows:
    want = manifest[row['song']]
    if not row['byte_exact'] or row['data_sha256'] != want['data_sha256'] or row['listing_sha256'] != want['listing_sha256']:
        raise SystemExit(f'FAIL: song {row["song"]} differs between the Swift CLI and ct_spc_seq.py')
print(f'{len(rows)} songs: Swift listings identical to the Python twin, byte-exact')

# SPC inspection uses a synthetic snapshot. No ROM-derived bytes are needed.
with tempfile.TemporaryDirectory(prefix='chronoforge-spc-') as directory:
    snapshot = Path(directory) / 'test.spc'
    data = bytearray(0x10200)
    data[:33] = b'SNES-SPC700 Sound File Data v0.30'
    data[0x21:0x2C] = bytes([26, 26, 27, 30, 0x34, 0x12, 1, 2, 3, 0xA5, 0xFE])
    data[0x100:0x10100] = bytes(range(256)) * 256
    snapshot.write_bytes(data)

    def spc(*options, code=0):
        result = subprocess.run([str(cli), 'music', 'spc-info', str(snapshot), *map(str, options)],
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
        return result.stdout

    info = json.loads(spc())
    assert info['registers'] == {'pc': 0x1234, 'a': 1, 'x': 2, 'y': 3, 'psw': 0xA5, 'sp': 0xFE}
    assert info['ramSHA256'] == hashlib.sha256(data[0x100:0x10100]).hexdigest()
    out = Path(directory) / 'info.json'
    spc('--out', out)
    assert json.loads(out.read_text()) == info
    spc('--out', snapshot, code=2)
    assert snapshot.read_bytes() == data
    before = out.read_bytes()
    snapshot.write_bytes(data[:100])
    spc('--out', out, code=1)
    assert out.read_bytes() == before
print('SPC inspection: registers, RAM hash, output and error preservation passed')
