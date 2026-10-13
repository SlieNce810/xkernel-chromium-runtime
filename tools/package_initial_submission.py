#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Package a frozen Git revision plus explicitly selected verified evidence."""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone, timedelta
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import zipfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default='HEAD')
    parser.add_argument('--selection', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    revision = subprocess.check_output(['git', 'rev-parse', args.revision], cwd=root, text=True).strip()
    selection = json.loads(args.selection.read_text(encoding='utf-8'))
    output = args.out.resolve()
    if output.exists():
        parser.error('Refuse to overwrite a completed submission package')
    output.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, tuple[bytes, int, str]] = {}
    archive = subprocess.check_output(['git', 'archive', '--format=tar', revision,
                                      'README.md', 'AGENTS.md', 'scripts', 'tools',
                                      'report', 'guest-overlays', 'docs'], cwd=root)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar:
            name = member.name
            if not member.isfile():
                continue
            if name.startswith('report/'):
                relative = name.removeprefix('report/')
                if '/' in relative and not relative.startswith('patches/'):
                    continue
            if name.startswith('docs/'):
                if not name.startswith('docs/demo/') and not (name.endswith('.pdf') and '/6 ' in name):
                    continue
            payload[name] = (tar.extractfile(member).read(), member.mode, 'git:' + revision)
    for directory in selection['evidence_directories']:
        resolved = (root / directory).resolve()
        if not resolved.is_relative_to(root) or not directory.startswith('evidence/'):
            raise ValueError('Evidence path escapes workspace')
        if not resolved.is_dir():
            raise FileNotFoundError(resolved)
        for path in sorted(resolved.rglob('*')):
            if not path.is_file() or path.suffix in {'.tar', '.gz'}:
                # Recovery transfer archives duplicate the verified original files.
                continue
            name = path.relative_to(root).as_posix()
            content = path.read_bytes()
            if name in payload and payload[name][0] != content:
                raise ValueError('Selected evidence differs from the frozen revision: ' + name)
            payload[name] = (content, 0o644, 'verified-evidence')
    for asset in selection.get('assets', []):
        path = (root / asset['source']).resolve()
        if not path.is_relative_to(root):
            raise ValueError('Asset path escapes workspace')
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != asset['sha256']:
            raise ValueError('Asset hash mismatch')
        name = asset['destination']
        if name.startswith('/') or '..' in Path(name).parts:
            raise ValueError('Invalid archive asset name')
        payload[name] = (content, 0o644, 'verified-asset')
    # Only selected deliverable evidence is present; Git sources do not contain evidence here.
    metadata = {'material_revision': revision, 'kernel_revision': selection['kernel_revision'],
                'created_at': datetime.now(timezone(timedelta(hours=8))).isoformat(),
                'administrative_forms': 'excluded at user request',
                'evidence_directories': selection['evidence_directories'],
                'manifest_scope': 'All payload files except submission-manifest.csv and SHA256SUMS'}
    payload['SOURCE-REVISION.json'] = ((json.dumps(metadata, ensure_ascii=False, indent=2) + '\n').encode(), 0o644, 'generated')
    forbidden = [b'-----BEGIN OPENSSH PRIVATE KEY-----', b'-----BEGIN RSA PRIVATE KEY-----',
                 b'-----BEGIN EC PRIVATE KEY-----']
    rows = []
    for name, (content, mode, source) in sorted(payload.items()):
        if any(line.strip() in forbidden for line in content.splitlines()):
            raise ValueError('Private key material in package: ' + name)
        rows.append({'path': name, 'bytes': len(content),
                     'sha256': hashlib.sha256(content).hexdigest(), 'source': source})
    manifest = io.StringIO(newline='')
    writer = csv.DictWriter(manifest, fieldnames=['path', 'bytes', 'sha256', 'source'])
    writer.writeheader()
    writer.writerows(rows)
    payload['submission-manifest.csv'] = (manifest.getvalue().encode('utf-8'), 0o644, 'generated')
    sums = ''.join(r['sha256'] + '  ' + r['path'] + '\n' for r in rows)
    payload['SHA256SUMS'] = (sums.encode('utf-8'), 0o644, 'generated')
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as package:
        for name, (content, mode, _) in sorted(payload.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 13, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(info, content)
    with zipfile.ZipFile(output) as package:
        if package.testzip() is not None:
            raise ValueError('ZIP CRC verification failed')
        for row in rows:
            if hashlib.sha256(package.read(row['path'])).hexdigest() != row['sha256']:
                raise ValueError('Packaged file digest mismatch')
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.zip.sha256').write_text(digest + '  ' + output.name + '\n', encoding='utf-8')
    output.with_suffix('.manifest.csv').write_text(manifest.getvalue(), encoding='utf-8', newline='')
    summary = {'path': str(output), 'bytes': output.stat().st_size, 'sha256': digest,
               'files': len(payload), 'material_revision': revision}
    output.with_suffix('.summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
