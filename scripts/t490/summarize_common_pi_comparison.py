#!/usr/bin/env python3
"""Summarize paired T490 before/after raw metrics without overwriting input."""
from __future__ import annotations
import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import statistics

METRICS = {
    'single_first_navigation': ('s', '15-second guest log polling; not page completion'),
    'first_passing_screendump': ('s', 'first strict 1280x800 screenshot; screenshot interval 15 s'),
    'peak_qemu_rss_kb': ('kB', 'host-side QEMU RSS; not guest Chromium RSS'),
    'qemu_cpu_percent_one_core': ('%', 'host-side QEMU CPU, one-core scale'),
}


def read(path: Path) -> dict[str, list[float]]:
    result: dict[str, list[float]] = {}
    with path.open(encoding='utf-8', newline='') as stream:
        for row in csv.DictReader(stream):
            try:
                result.setdefault(row['metric'], []).append(float(row['value']))
            except (KeyError, TypeError, ValueError):
                continue
    return result


def stats(values: list[float]) -> dict:
    return {'n': len(values), 'raw': values, 'median': statistics.median(values),
            'min': min(values), 'max': max(values), 'range': max(values) - min(values)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        parser.error('Refuse to overwrite a completed comparison')
    before, after = read(args.before), read(args.after)
    for dataset, label in [(before, 'before'), (after, 'after')]:
        for name in ('single_gate', 'page_assertion', *METRICS):
            vals = dataset.get(name, [])
            if len(vals) != 5:
                parser.error(f'{label}: {name} requires exactly five samples, got {len(vals)}')
            if len(dataset.get(name, [])) != len(set(dataset.get(name, []))) and name in ('single_gate','page_assertion'):
                pass
    for dataset, label in [(before, 'before'), (after, 'after')]:
        for name in ('single_gate', 'page_assertion'):
            if any(value != 1 for value in dataset[name]):
                parser.error(f'{label}: functional gate/page not passed in all five runs')
    comparisons = {}
    scores = {}
    for name, (unit, limit) in METRICS.items():
        left, right = stats(before[name]), stats(after[name])
        improvement = ((left['median'] - right['median']) / left['median'] * 100
                       if left['median'] > 0 else None)
        comparison = {'unit': unit, 'definition': limit, 'before': left, 'after': right,
                      'improvement_percent': improvement}
        if name == 'first_passing_screendump':
            step = 15.0
            b_earliest = max(0.0, left['median'] - step)
            a_latest = right['median']
            conservative_gain = max(0.0, (b_earliest - a_latest) / b_earliest * 100) if b_earliest else 0.0
            comparison['sampling_interval_seconds'] = step
            comparison['conservative_improvement_percent_after_sampling_bounds'] = conservative_gain
            improvement_for_score = conservative_gain
        else:
            improvement_for_score = improvement
        scores[name] = 3 if improvement_for_score >= 30 else 2 if improvement_for_score >= 15 else 1 if improvement_for_score >= 5 else 0
        comparisons[name] = comparison
    result = {'created_at': datetime.now(timezone.utc).isoformat(),
              'measurement_method': 'common PI-neutralizing user-space preload; same page, image, overlay, QEMU platform, autorun, observer and 15-second first-frame screenshots',
              'before_tag': 'v0.1-first-runnable = f8b92247922fb1127138bbd8830bec504913908f',
              'after_commit': '2a1b101ccf97ed255821b85628f366700089cda3',
              'before_csv_sha256': __import__('hashlib').sha256(args.before.read_bytes()).hexdigest(),
              'after_csv_sha256': __import__('hashlib').sha256(args.after.read_bytes()).hexdigest(),
              'functional_gates': {'before': before['single_gate'], 'after': after['single_gate']},
              'strict_page_assertions': {'before': before['page_assertion'], 'after': after['page_assertion']},
              'metrics': comparisons, 'metric_improvement_points': scores,
              'limitations': ['preload disables PI mutex protocol for BOTH versions; it is a compatibility adapter, not part of the normal unadapted runtime',
                              'first-frame time is bracketed by screenshots 15 seconds apart; percentages near this resolution are reported conservatively',
                              'renderer process creation is not applicable to the single-process configuration']}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    markdown = ['# T490 common-stack before/after measurement', '',
                f"Created: {result['created_at']}", '',
                'Both versions were measured five times with the same common user-space PI adapter, page, image, overlay, QEMU settings, screenshot policy and host observer. The adapter alters pthread mutex PI requests for both versions; results describe this controlled compatibility route.', '',
                '| Metric | Before median (min–max) | After median (min–max) | Median change | Conservative change / score points |',
                '|---|---:|---:|---:|---:|']
    for key, m in comparisons.items():
        b, a = m['before'], m['after']
        pct = m['improvement_percent']
        pct_text = 'n/a' if pct is None else f'{pct:.2f}%'
        score_pct = m.get('conservative_improvement_percent_after_sampling_bounds', pct or 0)
        markdown.append(f"| {key} | {b['median']:.3f} ({b['min']:.3f}–{b['max']:.3f}) {m['unit']} | {a['median']:.3f} ({a['min']:.3f}–{a['max']:.3f}) {m['unit']} | {pct_text} | {score_pct:.2f}% / {scores[key]} |")
    markdown += ['', '## Evidence', '',
                 f"Before: {args.before.as_posix()} (SHA-256 {result['before_csv_sha256']})",
                 f"After: {args.after.as_posix()} (SHA-256 {result['after_csv_sha256']})",
                 'Five original run directories on each side hold console.log, cmd.txt, env.txt, screenshots, guest logs and observer data. The JSON report contains per-run values, ranges, measurement definitions and limitations.',
                 '', '## Interpretation', '',
                 'Gate and strict page checks passed all five runs in each group. Stable gates are compatibility results and are not converted from 0 to 1 into a percentage. The first-frame metric is bounded by 15-second screenshot polling; the conservative score uses the lowest improvement compatible with that sampling interval. Host QEMU RSS and CPU represent the emulator process. The single-process setup has no renderer creation measurement.',
                 '']
    args.out.with_suffix('.md').write_text('\n'.join(markdown), encoding='utf-8')
    print(json.dumps({'output': str(args.out), 'points': scores}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
