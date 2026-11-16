#!/usr/bin/env python3
"""Build a relocatable app with recursive non-system dylibs. No third-party Python packages."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


root = Path(__file__).resolve().parents[1]
binary, tdlib = map(lambda p: Path(p).resolve(), sys.argv[1:])
app = root / 'dist/chatslaughter.app'
if app.exists():
    shutil.rmtree(app)
macos = app / 'Contents/MacOS'
frameworks = app / 'Contents/Frameworks'
resources = app / 'Contents/Resources'
for directory in [macos, frameworks, resources]:
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, macos / 'ChatSlaughter')

copied = {}
minimums = [(13, 0)]

def bundle(source, name=None):
    source = source.resolve()
    if source in copied:
        return copied[source]
    name = name or source.name
    copied[source] = name
    target = frameworks / name
    shutil.copy2(source, target)
    target.chmod(0o755)
    deps = run('otool', '-L', str(source)).splitlines()[2:]
    run('install_name_tool', '-id', '@rpath/' + name, str(target))
    for line in deps:
        dep = line.strip().split(' (')[0]
        if dep.startswith(('/usr/lib/', '/System/Library/')):
            continue
        actual = dep.replace('@loader_path', str(source.parent))
        if actual.startswith('@rpath/'):
            raise RuntimeError(f'Unresolved dependency {dep}; use an absolute-path TDLib build')
        dependency = Path(actual)
        if not dependency.is_file():
            raise RuntimeError(f'Missing dependency: {dependency}')
        dep_name = bundle(dependency)
        run('install_name_tool', '-change', dep, '@loader_path/' + dep_name, str(target))
    build = run('vtool', '-show-build', str(source))
    for version in re.findall(r'minos\s+(\d+(?:\.\d+)+)', build):
        minimums.append(tuple(map(int, version.split('.'))))
    run('codesign', '--force', '--sign', '-', str(target))
    return name

bundle(tdlib, 'libtdjson.dylib')
minimum = '.'.join(map(str, max(minimums)))
info = {
    'CFBundleName': 'chatslaughter', 'CFBundleDisplayName': 'chatslaughter',
    'CFBundleIdentifier': 'app.chatslaughter.mac', 'CFBundleExecutable': 'ChatSlaughter',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': minimum, 'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication', 'NSHumanReadableCopyright': 'Copyright 2026 mrak2n',
}
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
# Retain dependency licenses in the actual distributed bundle.
shutil.copy2(root / 'THIRD_PARTY_NOTICES.md', resources)
shutil.copy2(root / 'LICENSE', resources / 'chatslaughter-LICENSE')
for source, name in copied.items():
    for parent in [source.parent, source.parent.parent]:
        for pattern in ['LICENSE*', 'COPYING*', 'NOTICE*']:
            for license_file in parent.glob(pattern):
                if license_file.is_file():
                    shutil.copy2(license_file, resources / (name + '-' + license_file.name))
run('codesign', '--force', '--sign', '-', str(app))
run('codesign', '--verify', '--deep', '--strict', str(app))
for library in frameworks.iterdir():
    dependencies = run('otool', '-L', str(library)).splitlines()[1:]
    if any('/opt/homebrew/' in dep or '/usr/local/' in dep for dep in dependencies):
        raise RuntimeError(f'Non-relocatable dependency in {library.name}')
(root / 'dist/build-info.json').write_text(json.dumps({
    'app': str(app), 'architecture': run('uname', '-m'), 'minimum_macos': minimum,
    'libraries': list(copied.values()), 'signing': 'ad hoc; not notarized'
}, indent=2) + '\n')
print(app)
