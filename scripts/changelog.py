"""Generate release notes from the commits since the previous release."""
import collections
import subprocess
import sys

version, repository, previous, head = sys.argv[1:]
revision = f'{previous}..{head}' if previous else head
log = subprocess.check_output(['git', 'log', '--reverse', '--no-merges',
    '--format=%H%x09%s', revision], text=True)
groups = collections.defaultdict(list)
for line in log.splitlines():
    sha, subject = line.split('\t', 1)
    kind = subject.split(':', 1)[0].split('(', 1)[0].rstrip('!')
    group = {'feat': 'Features', 'fix': 'Fixes', 'perf': 'Performance',
        'docs': 'Documentation'}.get(kind, 'Other changes')
    groups[group].append(f'- {subject} ([{sha[:7]}](https://github.com/{repository}/commit/{sha}))')
print(f'# Omil {version}\n')
for group in ['Features', 'Fixes', 'Performance', 'Documentation', 'Other changes']:
    if groups[group]:
        print(f'## {group}\n\n' + '\n'.join(groups[group]) + '\n')
if not groups:
    print('No new non-merge commits since the previous release.\n')
if previous:
    print(f'[Full changelog](https://github.com/{repository}/compare/{previous}...v{version})\n')
