#!/usr/bin/env python3
"""Measure a VoiceOS library copy with fixed local regression thresholds; writes only inside the copy."""
from pathlib import Path
import argparse, json, subprocess, sys, time
from datetime import datetime, timezone

SQLITE = '/usr/bin/sqlite3'
KEYS = ('open', 'snapshot', 'search', 'mirror')
MAIN_TABLES = ('sources', 'claims', 'actions', 'transcripts', 'transcript_versions', 'assets', 'questions')
FIXED_QUERY = 'VoiceOS'
UNAVAILABLE = {
    'snapshot': 'unavailable: workspaceSnapshot 需要 VoiceOSStore 运行时；voiceos-check 没有该测量入口',
    'mirror': 'unavailable: MarkdownMirror 写入需要 Swift 运行时',
}

parser = argparse.ArgumentParser(
    description='在语音库副本上执行固定测量。open=打开库、PRAGMA integrity_check 并统计主要表；'
                'search=重建 FTS 索引并检索固定词 ' + FIXED_QUERY + '（检索上限 50）。'
                'snapshot 与 mirror 需要 Swift 运行时，报告为 unavailable。'
                '每个耗时是一次 /usr/bin/sqlite3 进程的墙钟，包含进程启动与首次打开开销。'
                'voiceos-check 只有 read 入口且需要构建，本脚本只测数据库层，不改仓库内文件。',
    epilog='示例：scripts/perf/baseline.py --library /tmp/voiceos-copy --max-ms open=200 --max-ms search=500 --output text')
parser.add_argument('--library', type=Path, required=True, help='语音库副本目录，须含 voiceos.sqlite；脚本会重建副本内的 search_index')
parser.add_argument('--max-ms', action='append', default=[], metavar='KEY=MS', help='耗时上限，可多次；key 取 open|snapshot|search|mirror')
parser.add_argument('--output', choices=['json', 'text'], default='json', help='json 输出完整结果；text 输出逐行摘要')
args = parser.parse_args()

thresholds = {}
for item in args.max_ms:
    key, separator, value = item.partition('=')
    if not separator or key not in KEYS:
        parser.error(f'--max-ms 需要 KEY=MS，KEY 取 {", ".join(KEYS)}：{item}')
    try:
        thresholds[key] = float(value)
    except ValueError:
        parser.error(f'--max-ms 的 MS 不是数字：{item}')
    if thresholds[key] < 0:
        parser.error(f'--max-ms 的 MS 不能为负：{item}')

library = args.library.resolve()
database = library / 'voiceos.sqlite'
if not database.is_file():
    print(f'缺少 {database}', file=sys.stderr)
    sys.exit(2)

def sqlite_input(sql):
    started = time.perf_counter()
    completed = subprocess.run([SQLITE, '-batch', '-bail', str(database)], input=sql, text=True, capture_output=True)
    return (time.perf_counter() - started) * 1000, completed

def rows_of(output):
    return [line.split('|') for line in output.splitlines() if line]

def failure_text(completed):
    lines = completed.stderr.strip().splitlines()
    return lines[-1] if lines else f'sqlite3 退出码 {completed.returncode}'

measurements = {}
evidence = {}

def record(key, milliseconds, status):
    measurements[key] = {'ms': None if milliseconds is None else round(milliseconds, 1), 'status': status}

_, probe = sqlite_input("SELECT name FROM sqlite_master WHERE type='table';")
if probe.returncode != 0:
    record('open', None, 'error: ' + failure_text(probe))
    record('search', None, 'error: ' + failure_text(probe))
else:
    tables = {line for line in probe.stdout.splitlines() if line}
    counted = [table for table in MAIN_TABLES if table in tables]
    open_sql = 'PRAGMA integrity_check;\n' + ''.join(f"SELECT '{table}', count(*) FROM {table};\n" for table in counted)
    open_ms, opened = sqlite_input(open_sql)
    if opened.returncode != 0:
        record('open', None, 'error: ' + failure_text(opened))
    else:
        lines = rows_of(opened.stdout)
        integrity = lines[0][0] if lines else ''
        evidence['integrity'] = integrity
        evidence['counts'] = {row[0]: int(row[1]) for row in lines[1:]}
        if integrity == 'ok':
            record('open', open_ms, 'ok')
        else:
            record('open', None, f'error: integrity_check 返回 {integrity}')
    if 'search_index' not in tables:
        record('search', None, 'unavailable: 副本没有 search_index 表')
    else:
        search_sql = f"""DELETE FROM search_index;
INSERT INTO search_index(kind, ref_id, title, body)
SELECT 'material', s.id, s.name, COALESCE(GROUP_CONCAT(v.text, ' '), '')
FROM sources s LEFT JOIN transcripts t ON t.source_id = s.id
LEFT JOIN transcript_versions v ON v.id = t.current_version_id
WHERE s.state != 'trashed' GROUP BY s.id;
INSERT INTO search_index(kind, ref_id, title, body) SELECT 'claim', id, statement, statement FROM claims;
INSERT INTO search_index(kind, ref_id, title, body) SELECT 'action', id, title, note FROM actions;
SELECT 'indexed', count(*) FROM search_index;
SELECT 'matches', count(*) FROM (SELECT snippet(search_index, 3, '', '', '…', 24) FROM search_index WHERE search_index MATCH '"{FIXED_QUERY}"' ORDER BY rank LIMIT 50);
"""
        search_ms, searched = sqlite_input(search_sql)
        if searched.returncode != 0:
            record('search', None, 'error: ' + failure_text(searched))
        else:
            rows = rows_of(searched.stdout)
            samples = {row[0]: int(row[1]) for row in rows if len(row) == 2}
            evidence['search_indexed'] = samples.get('indexed', 0)
            evidence['search_matches'] = samples.get('matches', 0)
            if not evidence['search_indexed']:
                record('search', None, 'error: 重建后 search_index 为空')
            else:
                record('search', search_ms, 'ok')

for key, status in UNAVAILABLE.items():
    record(key, None, status)

failures = []
for key, limit in thresholds.items():
    milliseconds = measurements[key]['ms']
    if milliseconds is None:
        failures.append((2, f'{key} 不可测，无法验证 {limit:g}ms 阈值'))
    elif milliseconds > limit:
        failures.append((1, f'{key} {milliseconds:.1f}ms 超过 {limit:g}ms'))
has_error = any(measurement['status'].startswith('error') for measurement in measurements.values())
passed = not has_error and not failures
exit_code = 2 if has_error or any(code == 2 for code, _ in failures) else (1 if failures else 0)
payload = {
    'library': str(library),
    'generated_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
    'measurements': measurements,
    'thresholds': thresholds,
    'evidence': evidence,
    'passed': passed,
}

if args.output == 'json':
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
else:
    print(f'library: {library}')
    for key in KEYS:
        measurement = measurements[key]
        milliseconds = '      -' if measurement['ms'] is None else f"{measurement['ms']:7.1f}"
        print(f'{key:8} {milliseconds} ms  {measurement["status"]}')
    if thresholds:
        print('thresholds: ' + ', '.join(f'{key}<={limit:g}ms' for key, limit in thresholds.items()))
    pieces = []
    if 'integrity' in evidence:
        pieces.append(f"integrity={evidence['integrity']}")
    if 'counts' in evidence:
        pieces.append('counts=' + ','.join(f'{table}:{count}' for table, count in evidence['counts'].items()))
    if 'search_indexed' in evidence:
        pieces.append(f"indexed={evidence['search_indexed']}")
    if 'search_matches' in evidence:
        pieces.append(f"matches={evidence['search_matches']}")
    if pieces:
        print('evidence: ' + ' '.join(pieces))
    for _, message in failures:
        print(f'fail: {message}', file=sys.stderr)
    print('result: PASS' if passed else 'result: FAIL')
sys.exit(exit_code)
