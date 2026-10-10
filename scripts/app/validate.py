#!/usr/bin/env python3
"""Real subprocess-kill checks against the same Core used by the app.
Use only an authorized audio/video fixture. All scratch copies stay in a fresh output root.
"""
import argparse, hashlib, json, os, signal, sqlite3, subprocess
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--audio', type=Path, required=True)
p.add_argument('--video', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
binary = root / '.build/debug/voiceos-check'
a.output.mkdir(parents=True, exist_ok=False)

def run(command, target, fixture=None, crash=None):
    env = dict(os.environ)
    env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash: env['VOICEOS_TEST_CRASH_AT'] = crash
    args = [str(binary), command, str(target)]
    if fixture: args += [str(fixture), 'fixed-command']
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=90)
    (target.parent / (target.name + '-' + command + ('-' + crash if crash else '') + '.log')).write_text(result.stdout + result.stderr)
    if crash:
        assert result.returncode == -signal.SIGKILL, (command, crash, result.returncode, result.stderr)
        return
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

def facts(target):
    with sqlite3.connect(target / 'voiceos.sqlite') as db:
        assert db.execute('pragma integrity_check').fetchone()[0] == 'ok'
        assert not db.execute('pragma foreign_key_check').fetchall()
        source = db.execute('select id,state,relative_path,expected_hash,expected_bytes from sources').fetchall()
        assert len(source) == 1
        jobs = db.execute('select state from jobs').fetchall()
        transcripts = db.execute('select text from transcripts').fetchall()
        return source[0], jobs, transcripts

cases = []
for sample, fixture in [('A01', a.audio.resolve()), ('V01', a.video.resolve())]:
    original = hashlib.sha256(fixture.read_bytes()).hexdigest()
    for point in ['intent','copyChunk','copyComplete','sealed','renamed','savedUncommitted','savedCommitted']:
        target = a.output / (sample + '-' + point)
        run('import', target, fixture, point)
        first = run('read', target)
        second = run('read', target)
        assert first == second
        source, jobs, _ = facts(target)
        expected = 'interrupted' if point in ['intent','copyChunk'] else 'saved'
        assert source[1] == expected
        assert len(jobs) == (1 if expected == 'saved' else 0)
        if expected == 'saved': assert hashlib.sha256((target / source[2]).read_bytes()).hexdigest() == original
        cases.append(dict(sample=sample, checkpoint=point, state=source[1], stable_reopen=True, passed=True))
    for mutation in ['corrupt','missing','restart_without_input_reference']:
        target = a.output / (sample + '-' + mutation)
        run('import', target, fixture)
        source, _, _ = facts(target)
        managed = target / source[2]
        if mutation == 'corrupt': managed.write_bytes(b'damaged copy')
        elif mutation == 'missing': managed.unlink()
        # No source file deletion: importer never retains its path; use only the managed copy on restart.
        first = run('read', target); second = run('read', target)
        assert first == second
        source, jobs, _ = facts(target)
        expected = 'saved' if mutation == 'restart_without_input_reference' else 'quarantined'
        assert source[1] == expected and len(jobs) == 1
        assert jobs[0][0] == ('queued' if expected == 'saved' else 'blocked')
        cases.append(dict(sample=sample, case=mutation, state=expected, passed=True))
    for point in ['jobClaimed','transcriptUncommitted','transcriptCommitted']:
        target = a.output / (sample + '-' + point)
        run('import', target, fixture)
        run('transcribe', target, crash=point)
        run('read', target)
        final = run('transcribe', target)
        repeat = run('transcribe', target)
        assert final == repeat
        source, jobs, transcripts = facts(target)
        assert source[1] == 'saved' and jobs == [('completed',)] and len(transcripts) == 1
        assert (len(transcripts[0][0]) > 0) if sample == 'A01' else (transcripts[0][0] == '')
        cases.append(dict(sample=sample, checkpoint=point, single_transcript=True, passed=True))
report = dict(schema=1, test='VoiceOS Core native media and process-kill integration', cases=cases, count=len(cases), passed=all(c['passed'] for c in cases), audio_uploaded=False, microphone_used=False, fixture_names_omitted=True)
(a.output / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(dict(count=len(cases), passed=report['passed']), ensure_ascii=False))
