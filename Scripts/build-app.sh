#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
build_dir="$project_dir/.build"
app_dir="$build_dir/MeetingAssistant.app"

cd "$project_dir"
swift build -c "$configuration" --product MeetingAssistant

binary_dir="$(swift build -c "$configuration" --show-bin-path)"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/MeetingAssistant" "$app_dir/Contents/MacOS/MeetingAssistant"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
signing_identity="${MEETING_ASSISTANT_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    # Keep a stable designated requirement so macOS TCC recognizes rebuilt local versions.
    codesign --force --sign - \
        --requirements '=designated => identifier "com.local.MeetingAssistant"' \
        "$app_dir"
else
    codesign --force --sign "$signing_identity" "$app_dir"
fi

echo "$app_dir"
