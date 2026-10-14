#!/usr/bin/env python3
"""Build the allowlisted T490 initial-round delivery from a frozen revision."""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import zipfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default='HEAD')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    revision = subprocess.check_output(['git', 'rev-parse', args.revision], cwd=root, text=True).strip()

    def git_file(name: str) -> bytes:
        return subprocess.check_output(['git', 'show', f'{revision}:{name}'], cwd=root)

    selection = json.loads(git_file('submission/selection.json'))
    output = args.out.resolve()
    if output.exists():
        parser.error('Refuse to overwrite a completed delivery')
    payload: dict[str, tuple[bytes, str]] = {}
    for item in selection['files']:
        destination = item['destination']
        parts = PurePosixPath(destination).parts
        if destination.startswith('/') or '..' in parts or '\\' in destination:
            raise ValueError('Unsafe archive name: ' + destination)
        if destination in payload:
            raise ValueError('Duplicate destination: ' + destination)
        if any(term in destination.lower() for term in ('wsl', 'windows', '.ps1', '.bat', '.cmd', '.workbuddy')):
            raise ValueError('Development-only material selected: ' + destination)
        source = (root / item['source']).resolve()
        if not source.is_relative_to(root):
            raise ValueError('Source escapes workspace')
        data = git_file(item['source']) if item['kind'] == 'git' else source.read_bytes()
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Selected file changed: ' + item['source'])
        for token in (b'-----BEGIN OPENSSH PRIVATE KEY-----', b'-----BEGIN RSA PRIVATE KEY-----'):
            if token in data:
                raise ValueError('Private key content: ' + item['source'])
        payload[destination] = (data, item['source'])
    metadata = {
        'material_revision': revision,
        'kernel_revision': selection['kernel_revision'],
        'created_at': datetime.now(timezone.utc).isoformat(),
        'scope': 'Native T490 Linux; one curated evidence set and one full demonstration video',
        'base_image': selection['base_image'],
    }
    payload['SOURCE-REVISION.json'] = ((json.dumps(metadata, ensure_ascii=False, indent=2) + '\n').encode(), 'generated')
    rows = [{'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'original_source': source}
            for name, (data, source) in sorted(payload.items())]
    stream = io.StringIO(newline='')
    writer = csv.DictWriter(stream, fieldnames=['path', 'bytes', 'sha256', 'original_source'])
    writer.writeheader()
    writer.writerows(rows)
    manifest = stream.getvalue()
    payload['manifest.csv'] = (manifest.encode('utf-8'), 'generated')
    payload['SHA256SUMS'] = (''.join(row['sha256'] + '  ' + row['path'] + '\n' for row in rows).encode(), 'generated')
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, (data, _) in sorted(payload.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 14, 0, 0, 0))
            info.create_system = 3
            mode = 0o755 if name.endswith(('.sh', '.py')) else 0o644
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC failed')
        for row in rows:
            if hashlib.sha256(archive.read(row['path'])).hexdigest() != row['sha256']:
                raise ValueError('Archive file digest failed: ' + row['path'])
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.zip.sha256').write_text(f'{digest}  {output.name}\n', encoding='utf-8')
    output.with_suffix('.manifest.csv').write_text(manifest, encoding='utf-8', newline='')
    summary = {'file': output.name, 'bytes': output.stat().st_size, 'files': len(payload),
               'sha256': digest, 'material_revision': revision}
    output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
