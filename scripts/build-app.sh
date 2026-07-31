#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
build_dir="$project_dir/.build/arm64-apple-macosx/$configuration"
app_dir="$project_dir/build/MinuteMark.app"

cd "$project_dir"
swift build -c "$configuration"

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$build_dir/MinuteMark" "$app_dir/Contents/MacOS/MinuteMark"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/MinuteMark.icns" "$app_dir/Contents/Resources/MinuteMark.icns"

signing_identity="${MINUTEMARK_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(
        security find-identity -v -p codesigning 2>/dev/null |
            sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' |
            head -1
    )
fi

if [[ -n "$signing_identity" ]]; then
    codesign --force --deep --sign "$signing_identity" "$app_dir"
    echo "Signed with $signing_identity"
else
    codesign --force --deep --sign - "$app_dir"
    echo "Warning: no development identity found; used ad-hoc signing."
fi

echo "$app_dir"
