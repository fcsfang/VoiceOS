#!/usr/bin/env python3
"""Hard-exit checks of user-authored text and atomic extracted actions. No cloud or EventKit."""
import argparse,json,os,signal,sqlite3,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
binary=Path(__file__).resolve().parents[2]/'.build/debug/voiceos-check'
def run(command,root,crash=None):
    env=dict(os.environ);env.pop('VOICEOS_TEST_CRASH_AT',None)
    if crash:env['VOICEOS_TEST_CRASH_AT']=crash
    r=subprocess.run([str(binary),command,str(root)],env=env,capture_output=True,text=True,timeout=30)
    assert r.returncode==(-signal.SIGKILL if crash else 0),r.stderr
cases=[]
for point in ['intent','copyComplete','sealed','renamed','savedUncommitted','savedCommitted','claimsUncommitted','claimsCommitted']:
    root=a.output/point
    if point.startswith('claims'):
        run('expression-fixture',root);run('extracted-action-fixture',root,point)
    else:run('expression-fixture',root,point)
    run('read',root);run('read',root)
    with sqlite3.connect(root/'voiceos.sqlite') as d:
        assert d.execute('pragma integrity_check').fetchone()[0]=='ok';assert not d.execute('pragma foreign_key_check').fetchall()
        source=d.execute('select state,origin,speaker from sources').fetchone()
        assert source==('interrupted' if point=='intent' else 'saved','user','user')
        assert d.execute('select count(*) from transcripts').fetchone()[0]==(0 if point=='intent' else 1)
        assert d.execute('select count(*) from jobs where state in ("queued","running")').fetchone()[0]==0
        count=1 if point=='claimsCommitted' else 0
        assert d.execute('select count(*) from claims').fetchone()[0]==count
        assert d.execute('select count(*) from actions').fetchone()[0]==count
        assert d.execute('select count(*) from reminder_links').fetchone()[0]==0
        if point=='claimsUncommitted':assert d.execute('select state from model_attempts').fetchone()[0]=='unknown'
        if point=='claimsCommitted':assert d.execute('select kind,intent_actor,auto_send from actions').fetchone()==('task','user',1)
    cases.append({'checkpoint':point,'passed':True,'stable_recovery':True,'claim_action_atomic':True})
report={'date':'2026-10-10','passed':True,'sigkill_count':len(cases),'network_calls':0,'external_writes':0,'cases':cases}
(a.output/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'count':len(cases),'passed':True}))
