#!/usr/bin/env python3
"""Compile and run submission probes on Linux; preserve failures as evidence."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cross-cc', default='aarch64-linux-musl-gcc')
    parser.add_argument('--native-cc', default='gcc')
    parser.add_argument('--qemu-user', default='qemu-aarch64')
    args = parser.parse_args()
    if platform.system() != 'Linux':
        parser.error('Run on Linux; --help is available on every platform')
    out = args.out.resolve()
    if out.exists():
        parser.error('Refuse to overwrite an existing evidence directory')
    out.mkdir(parents=True)
    (out / 'bin').mkdir()
    here = Path(__file__).resolve().parent
    names = ['submission_gap_probe', 'compatprobe', 'sandboxipcprobe',
             'fdprobe', 'seqpacketprobe', 'evprobe']
    results: list[dict] = []
    env = os.environ.copy()
    env['SEQPACKET_PROBE_PATH'] = str(out / 'seqpacket.sock')
    # Unix pathname sockets have a short ABI limit; use a unique short /tmp path.
    if len(env['SEQPACKET_PROBE_PATH'].encode()) >= 108:
        env['SEQPACKET_PROBE_PATH'] = f'/tmp/xk-seqpacket-{os.getpid()}.sock'
    fd_scratch = out / 'fdprobe-scratch'
    fd_scratch.mkdir()
    env['FDPROBE_TARGET_PATH'] = str(fd_scratch / 'target')
    env['FDPROBE_COUNT_PATH'] = str(fd_scratch / 'count')
    for name in names:
        source = here / (name + '.c')
        for arch, compiler in [('native', args.native_cc), ('aarch64', args.cross_cc)]:
            binary = out / 'bin' / (name + '-' + arch)
            command = [compiler, '-static', '-O2', '-Wall', '-Wextra',
                       str(source), '-o', str(binary)]
            record = {'probe': name, 'arch': arch,
                      'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                      'compile_command': command}
            try:
                build = subprocess.run(command, capture_output=True, timeout=90)
                (out / (name + '-' + arch + '-build.log')).write_bytes(build.stdout + build.stderr)
                record['compile_exit'] = build.returncode
                if build.returncode == 0:
                    record['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
                    run = [str(binary)] if arch == 'native' else [args.qemu_user, str(binary)]
                    record['run_command'] = run
                    execution = subprocess.run(run, env=env, capture_output=True,
                                               timeout=50, restore_signals=False)
                    record['run_exit'] = execution.returncode
                    (out / (name + '-' + arch + '.log')).write_bytes(execution.stdout + execution.stderr)
            except subprocess.TimeoutExpired as exc:
                record['error'] = 'TIMEOUT'
                (out / (name + '-' + arch + '-timeout.log')).write_bytes((exc.stdout or b'') + (exc.stderr or b''))
            except OSError as exc:
                record['error'] = str(exc)
            results.append(record)
    for scratch_name in ['target', 'count']:
        (fd_scratch / scratch_name).unlink(missing_ok=True)
    (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    facts = subprocess.check_output(['uname', '-a']) + subprocess.check_output(['lscpu'])
    (out / 'env.txt').write_bytes(facts)
    (out / 'timestamps.csv').write_text('finished_at\n' + datetime.now(timezone.utc).isoformat() + '\n')
    (out / 'cmd.txt').write_text('Commands and per-process return codes: results.json\n'
                              'AArch64 uses static musl + qemu-user on the Linux host, not x-kernel.\n'
                              'SIGPIPE remains ignored to observe EPIPE in the shutdown test.\n', encoding='utf-8')
    files = sorted(p for p in out.rglob('*') if p.is_file())
    (out / 'manifest.txt').write_text('\n'.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.relative_to(out).as_posix() for p in files) + '\n', encoding='utf-8')
    print(json.dumps([{'probe': r['probe'], 'arch': r['arch'], 'exit': r.get('run_exit'), 'error': r.get('error')} for r in results]))
    return 0 if all('run_exit' in r for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
