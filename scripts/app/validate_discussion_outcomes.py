#!/usr/bin/env python3
"""Ended, synthetic discussions; actual process kills, no network/mic/EventKit."""
import argparse,json,os,sqlite3,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--root',required=True,type=Path);p.add_argument('--binary',type=Path,default=Path('.build/debug/voiceos-check'));a=p.parse_args()
if a.root.exists():p.error('Use a fresh isolated root')
a.root.mkdir(parents=True,mode=0o700);binary=str(a.binary.resolve())
def run(command,root,*extra,crash=None):
    env=dict(os.environ);env.pop('VOICEOS_TEST_CRASH_AT',None)
    if crash:env['VOICEOS_TEST_CRASH_AT']=crash
    r=subprocess.run([binary,command,str(root),*map(str,extra)],env=env,capture_output=True,timeout=60)
    assert r.returncode==(-9 if crash else 0),(command,r.returncode,r.stderr.decode()[:300])
    return r

def state(root):
    with sqlite3.connect(f'file:{root / "voiceos.sqlite"}?mode=ro',uri=True) as db:
        rows=db.execute('SELECT o.id,o.conversation_id,o.snapshot_digest,o.result_digest,m.state,m.usage_json FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id').fetchall()
        claims=db.execute('SELECT id,ordinal,ownership,validity FROM claims ORDER BY ordinal').fetchall()
        actions=db.execute('SELECT id,claim_id,title,intent_actor,auto_send,validity FROM actions').fetchall()
        assert len(rows)==1 and len(claims)<=2 and len(actions)<=1
        assert db.execute('SELECT count(*) FROM model_attempts').fetchone()[0]==1
        assert db.execute('SELECT count(*) FROM reminder_links').fetchone()[0]==0
        return rows[0],claims,actions
checks=[]
for point in ['outcomeReserved','outcomeUncommitted','outcomeCommitted']:
    root=a.root/point;run('outcome-fixture',root,crash=point);run('read',root)
    before=state(root);complete=point=='outcomeCommitted'
    assert before[0][4]==('completed' if complete else 'unknown')
    assert len(before[1])==(2 if complete else 0) and len(before[2])==(1 if complete else 0)
    run('outcome-fixture',root);run('outcome-fixture',root);assert state(root)==before
    result=json.loads(run('outcome-read',root,before[0][1]).stdout);assert result['integrity']
    checks.append({'checkpoint':point,'state':before[0][4],'single_attempt_after_reopen_and_replay':True,'partial_claims_or_actions':False})
source=a.root/'outcomeCommitted';original=state(source)
for media in [False,True]:
    package=a.root/('media-package' if media else 'metadata-package');target=a.root/('media-restored' if media else 'metadata-restored')
    run('export',source,package,*(['media'] if media else []));run('restore',target,package);run('read',target)
    after=state(target);assert after[0]==original[0]
    assert [r[:3] for r in after[1]]==[r[:3] for r in original[1]] and all(r[3]=='frozen' for r in after[1])
    assert after[2][0][:-1]==original[2][0][:-1] and after[2][0][-1]=='frozen'
report={'date':'2026-10-11','schema':19,'package_version':18,'synthetic_only':True,'process_crashes':checks,'portable_round_trips':2,'cloud_calls':0,'microphone_calls':0,'external_task_writes':0}
(a.root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
