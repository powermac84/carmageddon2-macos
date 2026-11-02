#!/usr/bin/env python3
"""Fail closed if an application or source package contains original game data."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
forbidden = {'.exe', '.bdd', '.twt', '.smk', '.ogg', '.mp3', '.wav', '.dat', '.pix', '.p16', '.p08'}
errors = []
for path in root.rglob('*'):
    if path.is_symlink():
        errors.append(f'Symbolic link is not allowed in a release payload: {path.relative_to(root)}')
    if not path.is_file() or '.git' in path.relative_to(root).parts:
        continue
    name = path.name.lower()
    if path.suffix.lower() in forbidden or re.fullmatch(r'carma2web\.data\.\d+', name) or name in {'carma2data.js', 'carma2data.manifest.json'}:
        errors.append(f'Game asset in release: {path.relative_to(root)}')
    if path.stat().st_size > 50 * 1024 * 1024:
        errors.append(f'Unexpected file larger than 50 MB: {path.relative_to(root)}')
    if path.suffix.lower() in {'.swift', '.py', '.sh', '.md', '.txt', '.json', '.yml', '.yaml'}:
        text = path.read_text(errors='replace')
        if re.search(r'/Users/[A-Za-z0-9._ -]+/', text):
            errors.append(f'Personal/local path in release source: {path.relative_to(root)}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Data-free release audit passed: {root.name}')
