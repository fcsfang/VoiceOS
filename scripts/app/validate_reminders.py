#!/usr/bin/env python3
"""Real SIGKILL around a durable external-service stand-in; zero EventKit writes."""
import argparse,json,os,signal,sqlite3,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--package',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
binary=Path(__file__).resolve().parents[2]/'.build/debug/voiceos-check'
def run(command,root,extra=(),crash=None):
    env=dict(os.environ);env.pop('VOICEOS_TEST_CRASH_AT',None)
    if crash: env['VOICEOS_TEST_CRASH_AT']=crash
    r=subprocess.run([str(binary),command,str(root),*map(str,extra)],env=env,capture_output=True,text=True,timeout=60)
    assert r.returncode==(-signal.SIGKILL if crash else 0),r.stderr
cases=[]
for point in ['reminderReserved','reminderSaved','reminderFeedbackUncommitted','reminderFeedbackCommitted']:
    root=a.output/point
    run('restore',root,[a.package.resolve()]);run('policy-fixture',root);run('cognition-fixture',root);run('action-fixture',root)
    run('reminder-fixture',root,crash=point);run('read',root)
    remote=root/'fixture-reminders.json'
    before=remote.read_bytes() if remote.exists() else None
    with sqlite3.connect(root/'voiceos.sqlite') as db:
        state=db.execute('select state from reminder_links').fetchone()[0]
        assert state==('linked' if point.endswith('Committed') else 'unknown')
        assert db.execute('select state,version from actions').fetchone()==(('completed',2) if point.endswith('Committed') else ('open',1))
        assert db.execute('select count(*) from reminder_observations').fetchone()[0]==(1 if point.endswith('Committed') else 0)
    run('reminder-read-fixture',root);run('reminder-read-fixture',root)
    after=remote.read_bytes() if remote.exists() else None
    assert before==after, 'reconciliation must not write external data'
    with sqlite3.connect(root/'voiceos.sqlite') as db:
        assert db.execute('pragma integrity_check').fetchone()[0]=='ok';assert not db.execute('pragma foreign_key_check').fetchall()
        assert db.execute('select state,version from actions').fetchone()==(('open',1) if point=='reminderReserved' else ('completed',2))
        assert db.execute('select count(*) from action_revisions').fetchone()[0]==(0 if point=='reminderReserved' else 1)
        assert db.execute('select evidence_state from claims').fetchone()[0]=='unverified'
        assert db.execute('select state from reminder_links').fetchone()[0]==('missing' if point=='reminderReserved' else 'linked')
    cases.append({'checkpoint':point,'passed':True,'no_external_rewrite':True,'completion_at_most_once':True})
report={'date':'2026-10-10','passed':True,'count':len(cases),'sigkill_count':len(cases),'external_service_simulator':True,'eventkit_writes':0,'network_calls':0,'cases':cases}
(a.output/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'count':len(cases),'passed':True}))
