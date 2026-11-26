#!/bin/bash
set -euo pipefail
app=${1:?Supply the compiled simulator .app}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
runtime="com.apple.CoreSimulator.SimRuntime.iOS-$(xcrun --sdk iphonesimulator --show-sdk-version | tr . -)"
for model in 'iPhone SE (3rd generation)' 'iPhone 16 Pro Max'; do
    udid=$(xcrun simctl list devices available --json | jq -er --arg runtime "$runtime" --arg model "$model" '.devices[$runtime][] | select(.name == $model) | .udid' | head -1)
    xcrun simctl bootstatus "$udid" -b
    xcrun simctl install "$udid" "$app"
    xcrun simctl privacy "$udid" grant camera "$bundle_id"
    first=$(xcrun simctl launch "$udid" "$bundle_id")
    # A second launch must foreground the same process after it has created the camera view.
    sleep 5
    second=$(xcrun simctl launch "$udid" "$bundle_id")
    test "$first" = "$second"
    echo "PASS: $model ($runtime), $second"
    xcrun simctl shutdown "$udid"
done
