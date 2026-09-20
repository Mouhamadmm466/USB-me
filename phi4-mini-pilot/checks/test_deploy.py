"""Exercise deploy-only orchestration with fake SSH/Brev; never contacts the VM."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
FAKE='''
import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['TRACE_FILE'],'a') as f: f.write(json.dumps([name]+args)+'\\n')
if name=='uname': print('Linux')
elif name=='brev':
 assert args==['refresh'], 'Deploy must not start or create a VM'
elif name=='ssh':
 cmd=args[-1]
 assert 'python3 pilot.py validate' in cmd
 assert 'python3 viewer.py cases' in cmd
 assert 'workflow.sh run' not in cmd and 'start_model.sh' not in cmd and 'docker' not in cmd
 assert len(sys.stdin.buffer.read())>0
elif name=='python3':
 assert args in (['pilot.py','validate'],['viewer.py','cases'])
else: raise AssertionError('Unexpected command '+name)
'''
class DeployChecks(unittest.TestCase):
 def test_deploy_uploads_and_validates_without_inference_or_starting_vm(self):
  with tempfile.TemporaryDirectory() as td:
   root=pathlib.Path(td)
   shutil.copyfile(ROOT/'run-on-brev.sh',root/'run-on-brev.sh')
   for name in ['pilot.py','viewer.py','cases.json','system_prompt.txt','start_model.sh','workflow.sh','README.md','VALIDATION.md','RESULTS.md','COVERAGE.md','TESTS.md','tests.html','.gitignore']:
    (root/name).write_text('fixture')
   (root/'checks').mkdir(); (root/'datasets').mkdir()
   binpath=root/'bin';binpath.mkdir()
   for name in ['brev','ssh','scp','python3','uname']:
    path=binpath/name;path.write_text('#!'+sys.executable+'\n'+FAKE);path.chmod(0o755)
   trace=root/'trace.jsonl'
   env=dict(os.environ,PATH=str(binpath)+os.pathsep+os.environ['PATH'],TRACE_FILE=str(trace))
   result=subprocess.run(['bash',str(root/'run-on-brev.sh'),'deploy'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
   self.assertEqual(result.returncode,0,result.stdout)
   calls=[json.loads(x) for x in trace.read_text().splitlines()]
   self.assertEqual(sum(c[0]=='ssh' for c in calls),1)
   self.assertFalse(any(c[0]=='scp' for c in calls))
   self.assertIn('No model requests were made',result.stdout)
if __name__=='__main__': unittest.main()
