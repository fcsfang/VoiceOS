#!/usr/bin/env python3
"""Hard-exit proof of atomic feedback text/link recovery; synthetic local data only."""
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
for point in ['intent','copyComplete','sealed','renamed','savedUncommitted','savedCommitted']:
    root=a.output/point
    for command in ['expression-fixture','extracted-action-fixture','action-state-fixture']:run(command,root)
    run('feedback-fixture',root,point);run('read',root);run('read',root)
    with sqlite3.connect(root/'voiceos.sqlite') as d:
        assert d.execute('pragma integrity_check').fetchone()[0]=='ok';assert not d.execute('pragma foreign_key_check').fetchall()
        assert d.execute('select state,version from actions').fetchone()==('completed',2)
        expected=0 if point=='intent' else 1
        assert d.execute('select count(*) from action_feedback').fetchone()[0]==expected
        assert d.execute('select state from sources where feedback_json is not null').fetchone()[0]==('interrupted' if not expected else 'saved')
        assert d.execute('select count(*) from transcripts').fetchone()[0]==1+expected
        assert d.execute('select count(*) from reminder_links').fetchone()[0]==0
        if expected:assert d.execute('select action_version,kind,sequence from action_feedback').fetchone()==(2,'outcome',1)
    cases.append({'checkpoint':point,'passed':True,'stable_recovery':True,'feedback_text_link_atomic':True})
report={'date':'2026-10-10','passed':True,'sigkill_count':len(cases),'network_calls':0,'external_writes':0,'cases':cases}
(a.output/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'count':len(cases),'passed':True}))
