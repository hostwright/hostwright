#!/usr/bin/env python3
import argparse
import collections
import subprocess
import time


def process_tree_rss_kib(root_pid):
    snapshot = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,rss='], text=True)
    children = collections.defaultdict(list)
    memory = {}
    for line in snapshot.splitlines():
        pid, parent, rss = map(int, line.split())
        children[parent].append(pid)
        memory[pid] = rss
    total = 0
    pending = [root_pid]
    while pending:
        pid = pending.pop()
        total += memory.get(pid, 0)
        pending.extend(children[pid])
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('jobs', choices=['1', '3'])
    jobs = parser.parse_args().jobs
    subprocess.run(['/usr/sbin/sysctl', 'hw.memsize', 'hw.ncpu'], check=True)
    print(f'vm_stat before SwiftPM jobs={jobs}', flush=True)
    subprocess.run(['/usr/bin/vm_stat'], check=True)
    start = time.monotonic()
    peak_rss_kib = 0
    with subprocess.Popen(['/usr/bin/time', '-l', 'scripts/ci-swift.sh', 'build', '--jobs', jobs]) as build:
        while build.poll() is None:
            peak_rss_kib = max(peak_rss_kib, process_tree_rss_kib(build.pid))
            time.sleep(1)
    print(f'jobs={jobs} elapsed_seconds={time.monotonic() - start:.1f} peak_tree_rss_kib={peak_rss_kib}', flush=True)
    print(f'vm_stat after SwiftPM jobs={jobs}', flush=True)
    subprocess.run(['/usr/bin/vm_stat'], check=True)
    return build.returncode


if __name__ == '__main__':
    raise SystemExit(main())
