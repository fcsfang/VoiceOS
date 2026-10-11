#!/usr/bin/env python3
"""Local-only AI candidate derivation: actual process kills and stable migration."""
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
def state(root):
    with sqlite3.connect(f'file:{root / "voiceos.sqlite"}?mode=ro',uri=True) as db:
        d=db.execute('SELECT id,discussion_attempt_id,part_index,reference_kind,model_attempt_id,claim_id,state FROM discussion_claim_derivations').fetchall()
        m=db.execute('SELECT id,state,execution_kind,usage_json FROM model_attempts').fetchall()
        c=db.execute('SELECT id,ownership,evidence_state,validity,statement FROM claims').fetchall()
        assert len(d)==len(m)==1 and len(c)<=1
        assert m[0][2:] == ('discussion_derivation',None)
        assert db.execute('SELECT count(*) FROM actions').fetchone()[0]==0
        assert db.execute('SELECT count(*) FROM reminder_links').fetchone()[0]==0
        return d[0],m[0],c
checks=[]
for point in ['discussionCandidateReserved','discussionCandidateUncommitted','discussionCandidateCommitted']:
    root=a.root/point;run('discussion-candidate-fixture',root,crash=point);run('read',root)
    before=state(root);assert before[0][-1]==('completed' if point.endswith('Committed') else 'pending')
    assert len(before[2])==(1 if point.endswith('Committed') else 0)
    run('discussion-candidate-fixture',root);after=state(root);run('discussion-candidate-fixture',root);assert state(root)==after
    assert before[0][0]==after[0][0] and before[1][0]==after[1][0]
    assert after[0][-1]=='completed' and after[2][0][1:4]==('ai_candidate','unverified','current')
    checks.append({'checkpoint':point,'single_local_derivation':True,'explicit_resume_only':True})
source=a.root/'discussionCandidateCommitted';original=state(source)
for media in [False,True]:
    package=a.root/('media-package' if media else 'metadata-package');target=a.root/('media-restored' if media else 'metadata-restored')
    run('export',source,package,*(['media'] if media else []));run('restore',target,package);run('read',target)
    restored=state(target);assert restored[0]==original[0] and restored[1]==original[1]
    assert restored[2][0][:3]==original[2][0][:3] and restored[2][0][3]=='frozen'
report={'date':'2026-10-11','schema':18,'package_version':17,'synthetic_only':True,'process_crashes':checks,'portable_round_trips':2,'cloud_calls':0,'microphone_calls':0,'external_task_writes':0}
(a.root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
