# Fork build setup

Builds this checkout under your own bundle identifier and signing team, so it installs **alongside** the upstream Octonaut TestFlight build instead of replacing it.

## Setup

```bash
cp .env.example .env   # then fill in your team ID and bundle identifier
brew install xcodegen  # if you don't have it
```

## Usage

```bash
script/build_fork.sh               # build + install to a connected iPhone
script/build_fork.sh --simulator   # build + run on a booted simulator
script/build_fork.sh --open        # regenerate and open in Xcode
script/build_fork.sh --generate    # regenerate the project only
script/build_fork.sh --archive     # export a signed .ipa into build/
```

## How it works, and why

`project.yml` is never modified. `project.fork.yml` includes it and overrides only the identity-bearing settings, so pulling upstream stays a clean merge. The generated project is `Octofork.xcodeproj` (gitignored); upstream's `Octonaut.xcodeproj` is left alone.

Four things needed handling:

**Signing team.** Upstream hardcodes `DEVELOPMENT_TEAM: 22AYPY84RT` in the tracked `project.yml`. Yours comes from `.env`, which is gitignored, so no account identifier lands in a tracked file.

**iCloud container.** Upstream's entitlements hardcode `iCloud.com.leddytech.octonaut`, a container owned by the upstream team — signing against it with any other team fails. `fork/Octofork.entitlements` derives it as `iCloud.$(CFBundleIdentifier)` instead, so it follows whatever bundle ID you set and contains no account-specific value. The KVS and keychain-group entitlements already expanded from build settings upstream and needed no change.

**URL scheme.** Upstream registers `octonaut://`. If two installed apps claim one scheme, iOS picks between them arbitrarily and Reddit links may open the wrong app. XcodeGen's `include` *concatenates* arrays rather than overriding them, so the generated plist inherits upstream's entry next to yours — `script/prune_url_schemes.py` strips everything that is not this fork's scheme, and the build fails loudly if the result isn't exactly one entry.

**Info.plist collision.** Pointing `INFOPLIST_FILE` at `fork/` leaves upstream's `OctonautApp/Info.plist` to be copied as an ordinary resource, which collides with the product's own Info.plist (`Multiple commands produce ... Info.plist`). `EXCLUDED_SOURCE_FILE_NAMES: Info.plist` in the fork spec keeps it out of the resources phase without editing any tracked file.

## Verifying a build

```bash
codesign -dvv  <path to Octonaut.app>
codesign -d --entitlements :- <path to Octonaut.app> | plutil -p -
```

The identifier, `application-identifier`, iCloud container and keychain group should all carry your team prefix and bundle ID.
