#!/usr/bin/env python3
"""Offline conversion of pinned BGE; development-only Python, no user library access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('source', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
assert not a.output.exists(), 'requires fresh output'
manifest = json.loads((a.source / 'voiceos-manifest.json').read_text())
assert manifest['model'] == 'BAAI/bge-small-zh-v1.5'
assert manifest['revision'] == '7999e1d3359715c523056ef9478215996d62a620'
assert manifest['sha256']['model.safetensors'] == '354763b9b1357bc9c44f62c6be2276321081ed2567773608c0d0785b61d5a026'
assert manifest['sha256']['vocab.txt'] == '45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c'
assert manifest['sha256']['config.json'] == '3853a7979202c348751b753e36f579c41d8da7d36af617d3d907e1fc9b441f2a'
assert manifest['sha256']['tokenizer.json'] == '48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26'
assert manifest['sha256']['tokenizer_config.json'] == 'e6f3b96db926a37d4039995fbf5ad17de158dfb8f6343d607e4dbaad18d75f5a'
assert manifest['sha256']['special_tokens_map.json'] == 'b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3'
for name, digest in manifest['sha256'].items():
    assert hashlib.sha256((a.source / name).read_bytes()).hexdigest() == digest
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer
torch.set_num_threads(4)
model = AutoModel.from_pretrained(a.source, local_files_only=True, trust_remote_code=False, use_safetensors=True, attn_implementation='eager').eval()
tokenizer = AutoTokenizer.from_pretrained(a.source, local_files_only=True, trust_remote_code=False)

class Encoder(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.bert = model
    def forward(self, ids, mask, types):
        return self.bert(input_ids=ids, attention_mask=mask, token_type_ids=types).last_hidden_state[:, 0, :]

started = time.perf_counter()
wrapper = Encoder().eval()
examples = (torch.ones((1, 32), dtype=torch.long), torch.ones((1, 32), dtype=torch.long), torch.zeros((1, 32), dtype=torch.long))
traced = torch.jit.trace(wrapper, examples)
length = ct.RangeDim(lower_bound=2, upper_bound=512, default=32)
converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS13,
                       compute_precision=ct.precision.FLOAT32,
                       inputs=[ct.TensorType(name=n, shape=(1, length), dtype=np.int32) for n in ['input_ids', 'attention_mask', 'token_type_ids']],
                       outputs=[ct.TensorType(name='embedding')])
a.output.mkdir(parents=True)
converted.save(a.output / 'Encoder.mlpackage')
shutil.copy2(a.source / 'vocab.txt', a.output / 'vocab.txt')
cases = ['为这个句子生成表示以用于检索相关文章：把提取训练放到容易忘的时候会不会更有效？', '按遗忘曲线安排检索练习。', '条件满足才有效，尚未验证。', '学习做饭先练刀工。', 'ABC café İSTANBUL 你好🙂\t\n[MASK]', '中' * 256]
checks = []
for text in cases:
    tokens = tokenizer(text, return_tensors='pt', truncation=False)
    with torch.inference_mode():
        reference = wrapper(tokens['input_ids'], tokens['attention_mask'], tokens['token_type_ids']).numpy()[0]
    actual = converted.predict({n: tokens[n].numpy().astype(np.int32) for n in ['input_ids','attention_mask','token_type_ids']})['embedding'][0]
    cosine = float(np.dot(reference, actual) / (np.linalg.norm(reference) * np.linalg.norm(actual)))
    assert cosine > 0.99999, cosine
    checks.append({'text':text,'token_ids':tokens['input_ids'][0].tolist(),'reference_vector':(reference / np.linalg.norm(reference)).tolist(),'coreml_cosine':cosine})
(a.output / 'parity.json').write_text(json.dumps(checks,ensure_ascii=False)+'\n')
subprocess.run(['xcrun','coremlcompiler','compile',str(a.output / 'Encoder.mlpackage'),str(a.output)],check=True)
files = []
for file in sorted(a.output.rglob('*')):
    if file.is_file() and (file.relative_to(a.output).parts[0] == 'Encoder.mlmodelc' or file.name == 'vocab.txt'):
        files.append({'path':str(file.relative_to(a.output)),'bytes':file.stat().st_size,'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
result = {'format':'voiceos-bge-coreml-v1','model':manifest['model'],'revision':manifest['revision'],'source_sha256':manifest['sha256'],'precision':'float32','dimension':512,'max_tokens':512,'window_scalars':256,'overlap_scalars':96,'files':files,'coremltools_version':ct.__version__,'torch_version':torch.__version__,'elapsed_seconds':time.perf_counter()-started}
(a.output / 'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'files':len(files),'cosines':[v['coreml_cosine'] for v in checks],'bytes':sum(v['bytes'] for v in files),'elapsed_seconds':result['elapsed_seconds']}))
