#!/usr/bin/env python3
"""Turn the self-built playback options (#609) on or off in project.pbxproj.

    python3 Scripts/enthusiast-build.py --fel --height-audio   # both on
    python3 Scripts/enthusiast-build.py                        # back to the App Store set

--fel           DualLayerDolbyVision (Profile 7 FEL with both layers composed) and
                DolbyVisionStillReshaping (Profile 5 scrub stills).
--height-audio  TrueHDObjectAudio and DTSXObjectAudio: TrueHD Atmos and DTS:X keep their heights.

The app reads the traits at runtime and shows Settings > Playback > Dolby Vision FEL and
Height Speakers. App Store builds never carry them; CI refuses a commit that does.
"""
import argparse
import re

PATH = "Rivulet.xcodeproj/project.pbxproj"
FEL = ["DualLayerDolbyVision", "DolbyVisionStillReshaping"]
HEIGHT_AUDIO = ["TrueHDObjectAudio", "DTSXObjectAudio"]
REF = re.compile(r'(XCRemoteSwiftPackageReference "AetherEngine" \*/ = \{\n.*?\n\t\t\ttraits = \(\n)(.*?)(\t\t\t\);)', re.S)

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--fel", action="store_true", help="full Dolby Vision Profile 7 FEL")
parser.add_argument("--height-audio", action="store_true", help="TrueHD Atmos and DTS:X height channels")
args = parser.parse_args()

with open(PATH) as f:
    project = f.read()
match = REF.search(project)
if not match:
    raise SystemExit("AetherEngine traits not found in " + PATH)

traits = [t for t in re.findall(r"(\w+),", match[2]) if t not in FEL + HEIGHT_AUDIO]
traits += (FEL if args.fel else []) + (HEIGHT_AUDIO if args.height_audio else [])
block = "".join(f"\t\t\t\t{t},\n" for t in traits)
with open(PATH, "w") as f:
    f.write(project[:match.start(2)] + block + project[match.end(2):])
print("AetherEngine traits:", ", ".join(traits))
