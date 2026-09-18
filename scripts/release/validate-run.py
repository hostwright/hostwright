#!/usr/bin/env python3
import json
import sys
run = json.load(open(sys.argv[1]))
if (run.get('path') != '.github/workflows/' + sys.argv[2]
        or run.get('event') != 'workflow_dispatch' or run.get('head_branch') != 'main'
        or run.get('head_repository', {}).get('full_name') != 'hostwright/hostwright'
        or run.get('conclusion') != 'success' or run.get('status') != 'completed'
        or (len(sys.argv) > 3 and str(run.get('run_attempt')) != sys.argv[3])):
    raise SystemExit('run is not the exact successful protected trusted workflow')
