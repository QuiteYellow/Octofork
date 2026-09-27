#!/usr/bin/env python3
"""Reduce a generated Info.plist to this fork's URL scheme only.

XcodeGen's `include` concatenates arrays rather than overriding them, so the
plist generated from project.fork.yml inherits upstream's octonaut:// entry
alongside this fork's. Two installed apps claiming the same scheme means iOS
picks between them arbitrarily, so everything that is not this fork's scheme
is dropped here.
"""
import os
import plistlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: prune_url_schemes.py <Info.plist>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    if not os.path.exists(path):
        return 0

    try:
        scheme = os.environ["OCTOFORK_URL_SCHEME"]
        bundle = os.environ["OCTOFORK_BUNDLE_ID"]
    except KeyError as missing:
        print(f"error: {missing} is not set", file=sys.stderr)
        return 1

    with open(path, "rb") as handle:
        plist = plistlib.load(handle)

    kept = [
        entry
        for entry in plist.get("CFBundleURLTypes", [])
        if scheme in entry.get("CFBundleURLSchemes", [])
    ]

    if len(kept) != 1:
        print(
            f"error: {path}: expected exactly one '{scheme}' URL type, found {len(kept)}",
            file=sys.stderr,
        )
        return 1

    kept[0]["CFBundleURLName"] = bundle
    plist["CFBundleURLTypes"] = kept

    with open(path, "wb") as handle:
        plistlib.dump(plist, handle)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
