#!/usr/bin/env python3
"""Print the UDID of a physical iOS device to install onto.

`xcrun devicectl list devices` reports simulators and physical devices in the
same table, and device names contain spaces, so column slicing is unreliable.
This reads the JSON instead and filters on hardwareProperties.reality.

Prefers a device that is currently connected. Exits non-zero with a readable
message when there is nothing to install to.
"""
import json
import os
import subprocess
import sys
import tempfile


def devices() -> list[dict]:
    with tempfile.TemporaryDirectory() as workdir:
        output = os.path.join(workdir, "devices.json")
        subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", output],
            check=True,
            capture_output=True,
        )
        with open(output, encoding="utf-8") as handle:
            return json.load(handle)["result"]["devices"]


def main() -> int:
    try:
        found = devices()
    except subprocess.CalledProcessError as error:
        print(f"error: devicectl failed: {error}", file=sys.stderr)
        return 1

    physical = [
        device
        for device in found
        if device.get("hardwareProperties", {}).get("reality") == "physical"
    ]

    if not physical:
        print(
            "error: no physical iOS device found.\n"
            "       Connect your iPhone by cable, unlock it, and tap Trust.",
            file=sys.stderr,
        )
        return 1

    def is_connected(device: dict) -> bool:
        state = device.get("connectionProperties", {}).get("tunnelState")
        return state not in (None, "disconnected", "unavailable")

    # devicectl brings its tunnel up lazily, so a wired device that xcodebuild
    # can happily target still reports tunnelState "disconnected". Prefer a
    # device that is definitely up, but fall back to any paired one rather than
    # refusing to build -- xcodebuild gives a better error than we can here.
    chosen = next((device for device in physical if is_connected(device)), None)

    if chosen is None:
        paired = [
            device
            for device in physical
            if device.get("connectionProperties", {}).get("pairingState") == "paired"
        ]
        if not paired:
            print(
                "error: found a physical device but it is not paired.\n"
                "       Connect it by cable, unlock it, and tap Trust.",
                file=sys.stderr,
            )
            return 1
        chosen = paired[0]
        name = chosen.get("deviceProperties", {}).get("name", "?")
        print(
            f"note: {name} is paired but reports no active tunnel; trying anyway.",
            file=sys.stderr,
        )

    name = chosen.get("deviceProperties", {}).get("name", "?")
    print(chosen["hardwareProperties"]["udid"])
    print(f"selected device: {name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
