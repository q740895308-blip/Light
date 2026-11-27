#!/bin/bash
set -euo pipefail
app=${1:?Supply the compiled simulator .app}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
device_type="com.apple.CoreSimulator.SimDeviceType.${2:?Supply an iPhone simulator device type}"
codesign --verify --strict "$app"
runtime=$(xcrun simctl list runtimes --json | jq -er --arg device "$device_type" '
    [.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-")))
     | select(any(.supportedDeviceTypes[]?; .identifier == $device))]
    | sort_by([(.version == "18.5"), (.version | split(".") | map(tonumber))]) | last.identifier')
udid=$(xcrun simctl create "Stilltone-$2" "$device_type" "$runtime")
echo "Starting $device_type ($runtime)"
diagnostics() {
    local status=$?
    if [[ $status != 0 ]]; then
        xcrun simctl spawn "$udid" log show --last 3m --style compact --predicate \
            "process == 'FLCamera' OR eventMessage CONTAINS[c] '$bundle_id'" | tail -100 >&2 || true
        find "$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Logs/CrashReporter" \
            -type f -name 'FLCamera*.ips' -exec head -c 24000 {} \; >&2 || true
    fi
    xcrun simctl shutdown "$udid" || true
}
trap diagnostics EXIT
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant camera "$bundle_id"
launch=$(xcrun simctl launch "$udid" "$bundle_id")
echo "$launch"
pid=${launch##*: }
[[ "$pid" =~ ^[0-9]+$ ]]
sleep 12
ps -p "$pid" -o command= | grep -F '/FLCamera.app/FLCamera'
echo "PASS: $device_type ($runtime), PID $pid"
if [[ $2 == iPhone-14-Pro ]]; then
    temp_project=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/stilltone-menu-ui.XXXXXX")
    ditto "$(cd "$(dirname "$0")/.." && pwd)" "$temp_project"
    if ! ruby -rxcodeproj -e '' 2>/dev/null; then
        gem install --user-install --no-document xcodeproj -v 1.27.0
    fi
    ruby "$temp_project/Tests/create-menu-ui-target.rb" "$temp_project/FL-Camera.xcodeproj"
    xcodebuild test -project "$temp_project/FL-Camera.xcodeproj" -scheme MenuUITests \
        -configuration Release -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$temp_project/DerivedData" -parallel-testing-enabled NO \
        -resultBundlePath "${RUNNER_TEMP:-$temp_project}/stilltone-menu-ui.xcresult" \
        CODE_SIGN_IDENTITY=-
fi
