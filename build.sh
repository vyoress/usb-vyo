#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="$PWD/build/USB Vyo.app"
mkdir -p "$app/Contents/MacOS"
extra_flags=()
# Some CLT upgrades leave two declarations of SwiftBridging. Hide the
# obsolete one from this build only; never change the installed toolchain.
swift_headers="$(xcode-select -p)/usr/include/swift"
if [[ -f "$swift_headers/module.modulemap" && -f "$swift_headers/bridging.modulemap" ]] && diff -I 'Copyright' "$swift_headers/module.modulemap" "$swift_headers/bridging.modulemap" >/dev/null; then
    mkdir -p build/toolchain
    python3 - "$swift_headers/module.modulemap" "$PWD/build/toolchain" <<'PY'
import json
import sys
from pathlib import Path
directory = Path(sys.argv[2])
(directory / 'empty.modulemap').write_text('')
(directory / 'overlay.json').write_text(json.dumps({
    'version': 0,
    'roots': [{'type': 'file', 'name': sys.argv[1],
               'external-contents': str(directory / 'empty.modulemap')}]
}))
PY
    extra_flags=(-vfsoverlay "$PWD/build/toolchain/overlay.json")
fi
swiftc Sources/USBBar.swift -target "$(uname -m)-apple-macos13.0" -o "$app/Contents/MacOS/USBVyo" -O "${extra_flags[@]}" -framework AppKit -framework SwiftUI -framework IOKit -framework DiskArbitration -framework ServiceManagement
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign - "$app"
echo "$app"
