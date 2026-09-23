import json, subprocess

out = subprocess.run(['gh', 'api', 'repos/l1ratch/WSBridge/actions/runs?per_page=3'],
                     capture_output=True, text=True)
d = json.loads(out.stdout)
for r in d['workflow_runs']:
    print(r['id'], r['head_sha'][:7], r['status'], r['conclusion'])
