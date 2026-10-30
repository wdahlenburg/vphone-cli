#!/bin/zsh
# vphone-tier: build
set -euo pipefail

tests="${0:a:h}"
helper="$tests:h/LocationHelperProcess"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-bluetooth-advertisement.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$temporary/ModuleCache" \
    "$helper/VPhoneBluetoothAdvertisement.swift" \
    "$tests/BluetoothAdvertisementTests.swift" -o "$temporary/BluetoothAdvertisementTests"
"$temporary/BluetoothAdvertisementTests"

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$temporary/ModuleCache" \
    "$helper/VPhoneBluetoothATTTransport.swift" \
    "$tests/BluetoothATTTransportTests.swift" -o "$temporary/BluetoothATTTransportTests"
"$temporary/BluetoothATTTransportTests"

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -Xfrontend -disable-sandbox -module-cache-path "$temporary/ModuleCache" \
    "$tests:h/UI/HostDevices/VPhoneBluetoothBridge.swift" \
    "$tests/BluetoothBridgeTransportTests.swift" -o "$temporary/BluetoothBridgeTransportTests"
"$temporary/BluetoothBridgeTransportTests"
