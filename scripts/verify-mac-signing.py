"""Check distribution signing on every Mach-O file before notarization."""
import pathlib
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
team = sys.argv[2]
magic = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca',
)}
errors = []
count = 0
for path in sorted(app.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as file:
        if file.read(4) not in magic:
            continue
    count += 1
    check = subprocess.run(['codesign', '-d', '--verbose=4', str(path)],
                           capture_output=True, text=True)
    metadata = check.stderr
    missing = []
    if check.returncode or 'Authority=Developer ID Application:' not in metadata:
        missing.append('Developer ID Application signature')
    if f'TeamIdentifier={team}\n' not in metadata:
        missing.append('expected signing team')
    if 'Timestamp=' not in metadata:
        missing.append('secure timestamp')
    if not re.search(r'flags=.*\([^)]*\bruntime\b[^)]*\)', metadata):
        missing.append('hardened runtime')
    if missing:
        errors.append(f'{path.relative_to(app)}: missing {", ".join(missing)}')
if not count:
    errors.append('No Mach-O binaries found')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Distribution signatures verified on {count} Mach-O binaries.')
