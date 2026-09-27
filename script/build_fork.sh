#!/usr/bin/env bash
#
# Builds Octonaut under your own bundle identifier and signing team so it can
# be installed alongside the upstream TestFlight build.
#
# Identity values live in .env (untracked). project.yml is never modified --
# project.fork.yml overlays it, so pulling upstream stays a clean merge.
#
# Usage:
#   script/build_fork.sh                 build and install to a connected iPhone
#   script/build_fork.sh --simulator     build and run on a booted simulator
#   script/build_fork.sh --generate      regenerate the Xcode project only
#   script/build_fork.sh --archive       export a signed .ipa into build/
#   script/build_fork.sh --open          regenerate and open in Xcode
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

command -v xcodegen >/dev/null || die "xcodegen not installed. Run: brew install xcodegen"

# Each env file describes one installable variant. Everything downstream keys
# off OCTOFORK_PROJECT_NAME, so two variants never share a generated project
# or Info.plist.
ENV_FILE="${OCTOFORK_ENV:-.env}"
while [[ "${1:-}" == --env || "${1:-}" == --env=* ]]; do
    if [[ "$1" == --env=* ]]; then
        ENV_FILE="${1#--env=}"; shift
    else
        [[ -n "${2:-}" ]] || die "--env needs a file"
        ENV_FILE="$2"; shift 2
    fi
done

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Run: cp .env.example $ENV_FILE  (then fill it in)"

# shellcheck disable=SC1091
set -a; source "$ENV_FILE"; set +a

for var in OCTOFORK_DEVELOPMENT_TEAM OCTOFORK_BUNDLE_ID OCTOFORK_BUNDLE_PREFIX \
           OCTOFORK_DISPLAY_NAME OCTOFORK_URL_SCHEME OCTOFORK_PROJECT_NAME; do
    [[ -n "${!var:-}" ]] || die "$var is not set in $ENV_FILE (see .env.example)"
done

if [[ "$OCTOFORK_BUNDLE_ID" == "com.leddytech.octonaut" ]]; then
    die "OCTOFORK_BUNDLE_ID must differ from upstream's, or this replaces the TestFlight build."
fi

PROJECT="${OCTOFORK_PROJECT_NAME}.xcodeproj"
SCHEME="Octonaut"

generate() {
    info "Generating $PROJECT from $ENV_FILE  (bundle $OCTOFORK_BUNDLE_ID)"
    xcodegen generate --spec project.fork.yml --project . >/dev/null
    # Guard against a spec change silently reverting identity to upstream's.
    local actual
    actual="$(xcodebuild -project "$PROJECT" -target Octonaut -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}')"
    [[ "$actual" == "$OCTOFORK_BUNDLE_ID" ]] \
        || die "generated bundle id is '$actual', expected '$OCTOFORK_BUNDLE_ID'"
    info "Verified bundle identifier: $actual"

    # XcodeGen's `include` concatenates arrays instead of overriding them, so
    # the generated plists inherit upstream's octonaut:// scheme next to ours.
    for plist in "fork/${OCTOFORK_PROJECT_NAME}-Info.plist" \
                 "fork/${OCTOFORK_PROJECT_NAME}-Mac-Info.plist"; do
        [[ -f "$plist" ]] || continue
        python3 script/prune_url_schemes.py "$plist" \
            || die "failed to prune URL schemes in $plist"
    done
    info "Verified URL scheme: $OCTOFORK_URL_SCHEME"
}

device_udid() {
    python3 script/find_device.py
}

case "${1:---device}" in
    --generate)
        generate
        ;;

    --open)
        generate
        open "$PROJECT"
        ;;

    --simulator)
        generate
        local_sim="$(xcrun simctl list devices booted 2>/dev/null \
            | grep -oE '[0-9A-F-]{36}' | head -1)"
        [[ -n "$local_sim" ]] || die "no booted simulator. Boot one from Xcode or: xcrun simctl boot 'iPhone 17'"
        info "Building for simulator $local_sim"
        xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
            -destination "id=$local_sim" -quiet
        app="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$local_sim" \
            -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ CODESIGNING_FOLDER_PATH = /{print $2; exit}')"
        xcrun simctl install "$local_sim" "$app"
        xcrun simctl launch "$local_sim" "$OCTOFORK_BUNDLE_ID"
        info "Launched on simulator"
        ;;

    --archive)
        generate
        info "Archiving for device (Release)"
        rm -rf build/Octofork.xcarchive
        xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" \
            -destination 'generic/platform=iOS' \
            -archivePath build/Octofork.xcarchive \
            -allowProvisioningUpdates -quiet
        cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>development</string>
	<key>teamID</key><string>${OCTOFORK_DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key><string>automatic</string>
	<key>stripSwiftSymbols</key><true/>
	<key>compileBitcode</key><false/>
</dict>
</plist>
PLIST
        xcodebuild -exportArchive -archivePath build/Octofork.xcarchive \
            -exportOptionsPlist build/ExportOptions.plist \
            -exportPath build/export -allowProvisioningUpdates -quiet
        info "Exported: $(ls build/export/*.ipa 2>/dev/null || echo 'see build/export/')"
        ;;

    --device|"")
        generate
        udid="$(device_udid)" || die "could not select a device (see above)"
        [[ -n "$udid" ]] || die "could not determine device UDID"
        info "Building for device $udid"
        # -allowProvisioningUpdates lets Xcode register the device, create the
        # App ID and mint the iCloud container on first run.
        xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
            -destination "id=$udid" \
            -allowProvisioningUpdates -quiet
        app="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$udid" \
            -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ CODESIGNING_FOLDER_PATH = /{print $2; exit}')"
        [[ -d "$app" ]] || die "could not locate built .app"
        info "Installing $app"
        xcrun devicectl device install app --device "$udid" "$app"
        info "Installed. Launch it from the home screen."
        ;;

    -h|--help)
        sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;

    *)
        die "unknown option: $1  (try --help)"
        ;;
esac
