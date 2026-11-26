#!/usr/bin/env python3
import json,sys,csv
from pathlib import Path
source=Path(sys.argv[1]);output=Path(sys.argv[2])
data=json.loads(source.read_text());rows=[]
def walk(nodes,suite=''):
 for node in nodes:
  if node.get('nodeType')=='Test Suite':suite=node['name']
  if node.get('nodeType')=='Test Case':
   failures=[n.get('name','') for n in node.get('children',[]) if n.get('nodeType')=='Failure Message']
   rows.append({'suite':suite,'test':node['name'],'result':node.get('result','Unknown'),'seconds':node.get('durationInSeconds',''),'details':' | '.join(failures)})
  else:walk(node.get('children',[]),suite)
walk(data.get('testNodes',[]))
with output.with_suffix('.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=['suite','test','result','seconds','details']);writer.writeheader();writer.writerows(rows)
counts={status:sum(r['result']==status for r in rows) for status in sorted({r['result'] for r in rows})}
text='# Test results\n\n'+', '.join(f'{k}: {v}' for k,v in counts.items())+f'; total: {len(rows)}\n\n'
text+='| Suite | Test | Result | Seconds | Details |\n|---|---|---|---:|---|\n'
for row in rows:text+='| '+' | '.join(str(row[k]).replace('|','\\|').replace('\n',' ') for k in ['suite','test','result','seconds','details'])+' |\n'
output.with_suffix('.md').write_text(text)
