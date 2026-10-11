#!/usr/bin/env python3
"""Real process kills around synthetic shared-result extraction; no cloud/mic/EventKit."""
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
        outcome=db.execute('SELECT o.id,o.conversation_id,o.snapshot_digest,o.result_digest,m.state,m.usage_json FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id').fetchall()
        claims=db.execute('SELECT id,attempt_id,ordinal,ownership,review_version,validity FROM claims ORDER BY id').fetchall()
        actions=db.execute('SELECT id,claim_id,title,state,version,auto_send,validity FROM actions ORDER BY id').fetchall()
        models=db.execute('SELECT id,producer_sequence,state,result_digest FROM model_attempts ORDER BY producer_sequence').fetchall()
        assert len(outcome)==1 and len(models)==3
        snapshot=json.loads(db.execute('SELECT snapshot_json FROM conversation_outcome_attempts').fetchone()[0])
        assert len(snapshot['reusePlan']['priorResults'])==2 and len(snapshot['reusePlan']['personalTargets'])==1
        prior=[x for r in snapshot['reusePlan']['priorResults'] for x in r['claimIDs']];assert len(prior)==2
        assert db.execute("SELECT count(*) FROM claim_reviews WHERE decision='rejected'").fetchone()[0]==1
        assert db.execute('SELECT count(*) FROM reminder_links').fetchone()[0]==0
        assert [x[1] for x in models]==[1,2,3]
        assert sum(x[2]=='整理开发验证素材' and x[3]=='completed' and x[4]==2 for x in actions)==1
        return outcome[0],claims,actions,models
checks=[]
for point in ['outcomeReserved','outcomeUncommitted','outcomeCommitted']:
    root=a.root/point;run('outcome-reuse-fixture',root,crash=point);run('read',root)
    before=state(root);complete=point=='outcomeCommitted'
    assert before[0][4]==('completed' if complete else 'unknown')
    assert len(before[1])==(4 if complete else 2) and len(before[2])==(2 if complete else 1)
    run('outcome-reuse-fixture',root);run('outcome-reuse-fixture',root);assert state(root)==before
    result=json.loads(run('outcome-read',root,before[0][1]).stdout)
    assert result['integrity'] and len(result['outcomes'][0]['prior_claim_ids'])==2
    checks.append({'checkpoint':point,'state':before[0][4],'prior_identity_and_review_preserved':True,'prior_completed_task_preserved':True,'single_attempt_after_reopen_and_replay':True,'partial_new_claims_or_actions':False})
source=a.root/'outcomeCommitted';original=state(source)
for media in [False,True]:
    package=a.root/('media-package' if media else 'metadata-package');target=a.root/('media-restored' if media else 'metadata-restored')
    run('export',source,package,*(['media'] if media else []));run('restore',target,package);run('read',target)
    after=state(target);assert after[0]==original[0] and after[3]==original[3]
    assert [r[:-1] for r in after[1]]==[r[:-1] for r in original[1]]
    assert [r[:-1] for r in after[2]]==[r[:-1] for r in original[2]]
    with sqlite3.connect(f'file:{source / "voiceos.sqlite"}?mode=ro',uri=True) as db:
        frozen=set(x[0] for x in db.execute("SELECT c.id FROM claims c JOIN model_attempts m ON m.id=c.attempt_id WHERE m.provider='discussion_derivation' OR m.provider LIKE 'discussion_outcome:%'"))
    prior_claim_states={x[0]:x[-1] for x in original[1]}
    prior_action_states={x[0]:x[-1] for x in original[2]}
    assert all(x[-1]==('frozen' if x[0] in frozen else prior_claim_states[x[0]]) for x in after[1])
    assert all(x[-1]==('frozen' if x[1] in frozen else prior_action_states[x[0]]) for x in after[2])
report={'date':'2026-10-11','schema':19,'package_version':18,'synthetic_only':True,'process_crashes':checks,'portable_round_trips':2,'cloud_calls':0,'microphone_calls':0,'external_task_writes':0}
(a.root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
