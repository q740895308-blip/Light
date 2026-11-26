#!/bin/bash
set -euo pipefail
app=${1:?Supply the compiled simulator .app}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
runtime="com.apple.CoreSimulator.SimRuntime.iOS-$(xcrun --sdk iphonesimulator --show-sdk-version | tr . -)"
codesign --verify --strict "$app"
launch_app() {
    local attempt
    for attempt in 1 2 3; do
        if xcrun simctl launch "$udid" "$bundle_id"; then return 0; fi
        sleep 5
    done
    xcrun simctl spawn "$udid" log show --last 3m --style compact --predicate "eventMessage CONTAINS[c] '$bundle_id'" | tail -80 >&2
    return 1
}
for model in 'iPhone SE (3rd generation)' 'iPhone 16 Pro Max'; do
    udid=$(xcrun simctl list devices available --json | jq -er --arg runtime "$runtime" --arg model "$model" '.devices[$runtime][] | select(.name == $model) | .udid' | head -1)
    echo "Starting $model ($runtime)"
    xcrun simctl bootstatus "$udid" -b
    xcrun simctl install "$udid" "$app"
    xcrun simctl privacy "$udid" grant camera "$bundle_id"
    first=$(launch_app)
    # A second launch must foreground the same process after it has created the camera view.
    sleep 5
    second=$(launch_app)
    test "$first" = "$second"
    echo "PASS: $model ($runtime), $second"
    xcrun simctl shutdown "$udid"
done
