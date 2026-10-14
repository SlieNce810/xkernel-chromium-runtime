#!/usr/bin/env python3
"""Freeze the T490 list; stage candidate Git sources before running this tool."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
files = []


def add(source: str, destination: str, kind: str = 'evidence') -> None:
    path = ROOT / source
    if not path.is_file():
        raise FileNotFoundError(path)
    data = (subprocess.check_output(['git', 'show', ':' + source], cwd=ROOT)
            if kind == 'git' else path.read_bytes())
    files.append({'source': source, 'destination': destination, 'kind': kind,
                  'sha256': hashlib.sha256(data).hexdigest()})


for name in ('README.md', '技术方案.md', '证据说明.md'):
    add('submission/' + name, name, 'git')
for name in ('run-session.py', 'qemu_window.py', 'ppm2png.py', 'collect_single_metrics.py', 'observe_qemu.py', 'measure.py'):
    add('scripts/' + name, 'scripts/' + name, 'git')
runtime = '''reproduce_submission.sh t490_round.sh run_session_t490.sh round_assert.sh
ppm_assert.py pull_guest_logs.sh t490_inject_pages.sh guest-autostart.sh platform.env
t490_platform_check.sh autorun_single_initial.sh measure-single-initial.sh
run_interaction_round.sh qmp_input.py cdp_input.py autorun_submission_gaps.sh
submission_gap_probe.c compatprobe.c sandboxipcprobe.c fdprobe.c seqpacketprobe.c
evprobe.c run_linux_gap_baselines.py'''.split()
for name in runtime:
    add('scripts/t490/' + name, 'scripts/t490/' + name, 'git')
for name in ('index.html', 'interaction.html', 'layout.html'):
    add('scripts/testpage/' + name, 'scripts/testpage/' + name, 'git')

metadata = {'console.log', 'cmd.txt', 'env.txt', 'build-manifest.txt', 'pages.txt',
            'platform-compliance.txt', 'timestamps.csv', 'ppm-summary.txt'}


def round_files(name: str, destination: str, extra: tuple[str, ...] = ()) -> None:
    base = ROOT / 'evidence' / name
    for path in sorted(base.rglob('*')):
        if not path.is_file():
            continue
        rel = path.relative_to(base).as_posix()
        wanted = (rel in metadata or rel in extra
                  or (rel.startswith('screenshots/') and path.suffix == '.ppm')
                  or rel in {'guest/_root_single-initial.log', 'guest/_root_single-initial.csv',
                             'guest/_root_single-chromium.log', 'guest/_root_single-weston.log'})
        if wanted and path.stat().st_size:
            add(path.relative_to(ROOT).as_posix(), 'evidence/t490-final/' + destination + '/' + rel)


round_files('2026-10-13_t490-clean-submission-repro-v2-1350', 'main')
display = 'evidence/2026-10-14_t490-display-size-validation/'
for name in ('resolution-check.json', 'display-geometry.json', 'cmd.txt', 'env.txt', 'frame.ppm'):
    add(display + name, 'evidence/t490-final/display-check/' + name)
round_files('2026-10-02_t490-interaction-single-e2e-r20', 'interaction',
            ('interaction-assert.json', 'qmp-events.jsonl', 'screenshots/interaction-e2e.png'))
round_files('2026-10-13_t490-verify-c3-1013', 'layout',
            ('screenshots/shot-07-final.png', 'ppm-assert-shot-07-final.json'))
top = 'evidence/2026-10-02_t490-layout-e2e-r21/'
for name in ('screenshots/shot-03-at0180s.ppm', 'screenshots/layout-top.png',
             'layout-top-assert.json', 'cmd.txt', 'env.txt', 'build-manifest.txt'):
    add(top + name, 'evidence/t490-final/layout/top-view/' + name)
for name, dest in (
    ('2026-10-13_t490-submission-gaps-prctl-recheck', 'compatibility/guest'),
    ('2026-10-13_t490-linux-gap-baselines-v3-prctl', 'compatibility/linux'),
):
    base = ROOT / 'evidence' / name
    for path in sorted(base.rglob('*')):
        if not path.is_file() or not path.stat().st_size:
            continue
        rel = path.relative_to(base).as_posix()
        wanted = rel in {'console.log', 'cmd.txt', 'env.txt', 'build-manifest.txt', 'results.json', 'timestamps.csv'}
        wanted |= rel.startswith('guest/_root_submission')
        wanted |= dest.endswith('linux') and '/' not in rel and path.suffix == '.log'
        if wanted:
            add(path.relative_to(ROOT).as_posix(), 'evidence/t490-final/' + dest + '/' + rel)

metrics = ROOT / 'evidence/2026-10-13_measure-current-2a1b101'
for path in sorted(metrics.iterdir()):
    if path.name in {'raw.csv', 'summary.json', 'host.txt'} or (
            path.name.startswith('observer-run') and path.suffix in {'.csv', '.json'}):
        add(path.relative_to(ROOT).as_posix(), 'evidence/t490-final/performance/' + path.name)
times = ('103424', '103953', '104522', '105052', '105622')
for i, time in enumerate(times, 1):
    round_files(f'2026-10-13_t490-current-2a1b101-{i:02}-{time}', f'performance/run-{i:02}')
demo = 'evidence/2026-10-14_t490-record-complete-1440/'
for source, name in (
    ('run/cmd.txt', 'cmd.txt'), ('run/env.txt', 'env.txt'),
    ('run/build-manifest.txt', 'build-manifest.txt'),
    ('run/guest/_root_single-initial.log', 'guest-single-initial.log'),
    ('recording-start.json', 'recording-start.json'), ('recording-stop.json', 'recording-stop.json'),
    ('media-info.json', 'media-info.json'), ('video-result.json', 'video-result.json'),
):
    add(demo + source, 'evidence/t490-final/video-context/' + name)
add(demo + '2026-10-14-demo-full-flow.mp4', 'video/full-flow.mp4', 'asset')
add('evidence/2026-09-22_t490-stage0-freeze/src-snapshot/.config', 'config/xkernel.config')
add('report/submission-assets/x-kernel-source-2a1b101.tar.gz', 'assets/x-kernel-source-2a1b101.tar.gz', 'asset')
add('guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz',
    'guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz', 'git')

selection = {'kernel_revision': '2a1b101ccf97ed255821b85628f366700089cda3',
             'base_image': {'url': 'https://github.com/SlieNce810/xkernel-chromium-runtime/releases/download/v0.1-single-initial/agentos-weston.img.xz',
                            'xz_sha256': '6ed1bff70cabaa7d215693c10d2fef72f5f23d834031e260c70e5bcfae68e561',
                            'image_sha256': 'bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09'},
             'files': sorted(files, key=lambda item: item['destination'])}
(ROOT / 'submission/selection.json').write_text(json.dumps(selection, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'files': len(files), 'runtime_scripts': len(runtime) + 6,
                  'ppm': sum(x['destination'].endswith('.ppm') for x in files),
                  'bytes': sum((ROOT / x['source']).stat().st_size for x in files)}))
