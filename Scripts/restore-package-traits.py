#!/usr/bin/env python3
"""Put the committed SwiftPM package traits back into project.pbxproj.

Codemagic's `xcode-project use-profiles` re-saves the project through the
xcodeproj gem, which drops the `traits` attribute it does not know.
Run it after `use-profiles`; it fails the build if a trait cannot be restored.
"""
import re
import subprocess
import sys

PATH = "Rivulet.xcodeproj/project.pbxproj"
REF = re.compile(r'(\t\t(\w+) /\* XCRemoteSwiftPackageReference "([^"]+)" \*/ = \{\n.*?)(\n\t\t\};)', re.S)
TRAITS = re.compile(r'\n\t\t\ttraits = \(\n.*?\n\t\t\t\);', re.S)

committed = subprocess.run(["git", "show", f"HEAD:{PATH}"], check=True,
                           capture_output=True, text=True).stdout
wanted = {m[2]: (m[3], t[0]) for m in REF.finditer(committed) if (t := TRAITS.search(m[1]))}

with open(PATH) as f:
    project = f.read()

def restore(m):
    if m[2] not in wanted or TRAITS.search(m[1]):
        return m[0]
    return m[1] + wanted[m[2]][1] + m[4]

project = REF.sub(restore, project)
with open(PATH, "w") as f:
    f.write(project)

found = {m[2] for m in REF.finditer(project) if TRAITS.search(m[1])}
missing = [name for ref, (name, _) in wanted.items() if ref not in found]
if missing:
    sys.exit(f"Package traits missing for: {', '.join(missing)}")
for name, block in wanted.values():
    print(name, "traits:", ", ".join(re.findall(r"\t\t\t\t(\w+),", block)))
