# Physical Bluetooth Low Energy (experimental)

The bridge lets ordinary CoreBluetooth central apps inside an iPhone or iPad
guest discover and communicate with physical BLE peripherals near the Mac.
macOS owns the physical adapter and pairing. The guest uses Apple's BTVC virtual
controller; a host helper translates its ATT requests into CoreBluetooth GATT
operations over VSOCK 1340.

This is a research feature. The initial physical-device validation used an
iOS 26.6.2 guest and an unmodified third-party app: discovery, application
authentication, notifications and a firmware transfer worked. The patch
declaration permits checking iOS 18 and later, including iOS 27 and newer. Each
binary
must independently match the semantic patch patterns and runtime hook ABI;
admission is not a claim that every version works. The iOS 26.5 capability-query
layout is covered by regression tests; a booted 26.5 guest's generic scanning
app reached poweredOn and discovered 17 nearby peripherals. Physical GATT
connections on that version still need hardware validation. The actual iOS 18.6
binary rejects the scan patch and lacks the native classes required by the hook; physical bridging
on 18.6 needs a separate port. Xcode builds both Bluetooth guest components for
iOS 18.0, but that does not supply the missing runtime interfaces. Apple TV,
HomePod and Watch physical bridging have not been validated.

## Enable

Build the complete VPhone bundle using the repository's usual Xcode workflow.
Use that same bundle's CLI for patch selection, environment installation and
launch. Keep your VM's existing preset and other overrides when selecting the
new patch: `fw set-patches` replaces the selection record.

For a machine using the standard preset and no other overrides:

```zsh
vphone-cli fw set-patches lab --preset standard --allow system-bluetoothd-exp-btvc_advertisement_passup
```

Stop the guest, then apply the selection with `vphone-cli cfw update-environment
lab` using the usual administrator workflow. The guest scan patch, controller
hook and persistent bridge must come from this bundle. Reboot after installation;
updating vphoned alone does not install the launch daemon or scan patch.

Start the host bridge explicitly:

```zsh
VPHONE_BLUETOOTH=1 vphone-cli vm launch lab
```

Allow Bluetooth access in the macOS prompt and grant Bluetooth access to the
guest app. The helper runs inside the bundle's VPhoneLocation.app so macOS can
attribute this permission. When launched by Launchpad the responsible app's
privacy grant also applies. There is no Launchpad Bluetooth toggle yet; the
environment-variable workflow above is the tested CLI entry point.

Put the peripheral into its normal advertising/pairing mode. The guest sees a
stable synthetic address derived from macOS's peripheral UUID rather than the
physical radio address. macOS supplies aggregated advertisement fields, rebuilt
into legacy advertisement/scan-response pairs; data that cannot fit is omitted
as a whole typed field.

## Operations and limits

- Central discovery, primary service/characteristic/descriptor enumeration,
  reads, writes, and notification/indication subscriptions are translated.
- ATT MTU is derived from host write capacity; 16-, 32- and 128-bit
  CoreBluetooth UUIDs are converted to legal ATT representations.
- Guest disconnect requests release the physical session. BTVC alone reports
  the guest connection-complete event; the helper must never synthesize another.
- The physical peripheral's ATT handles are replaced by a virtual handle table.
  Included/secondary service discovery, prepared/execute writes, reliable long
  writes, signed writes, peripheral advertising, L2CAP CoC and EATT are not
  implemented. Unsupported ATT requests return errors.
- Bluetooth Classic, audio profiles and raw HCI/radio passthrough are outside
  this component. Physical pairing/encryption belongs to macOS, so guest pairing
  and security-level semantics are not reproduced exactly.
- Handles and peer addresses come from native BTVC connection-complete events;
  lifetime identifiers reject replies for reused handles. Physical disconnects
  and connection/discovery timeout failures request native controller cleanup.
  Start with one guest app and one physical peripheral until concurrent-device
  behavior has hardware coverage. A helper/guest-controller restart
  can require reconnecting the app; transparent recovery is not promised.
- Host transport backpressure disconnects the bridge instead of blocking the VM's UI.
  Indications are queued until the guest confirms the previous indication.
- Reads of actively notifying characteristics return ATT Request Not Supported:
  CoreBluetooth uses the same callback for reads and notifications without
  request identity. Service Changed/database invalidation remains incomplete.

This uses private Apple interfaces and an opt-in bluetoothd executable patch.
Unknown binary patterns are rejected before writing, and unsupported Objective-C
method signatures leave native handlers untouched. The BTVC WebSocket rejects
peers from other machines; the controller endpoint is guest-loopback-only.
Neither endpoint constitutes isolation between apps inside a research guest.

## Capture

Use a new writable file path for every capture:

```zsh
VPHONE_BLUETOOTH=1 VPHONE_BLUETOOTH_PCAP=/tmp/lab-ble-001.pcap vphone-cli vm launch lab
```

The helper writes DLT 201 Bluetooth HCI H4 with direction headers. These packets
represent translated ATT at the bridge, not over-the-air radio frames. Existing
files are preserved, and new captures use mode 0600. Capture is disabled without
the variable. Files can include identities, credentials and firmware contents.
Keep captures and device-specific update images outside commits.

## Disable

Stop the VM, remove the per-patch allow override (or explicitly block the patch)
while preserving other choices, and run `cfw update-environment` again. The
installer restores bluetoothd from its original backup and removes the controller
hook and bridge daemon. Launch without `VPHONE_BLUETOOTH=1` to leave the host
radio unshared.

## Verify and contribute

```zsh
zsh VPhoneExecutable/VPhoneVirtualization/Tests/run-bluetooth-advertisement-tests.sh
make -C VPhoneGuestComponents test-bluetooth-controller test-injection-environment
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build
```

Also run FirmwarePatcherTests for the Bluetooth feature flag and bundled
patch-set catalogue. Tests cover packet framing, malformed lengths, UUID
encoding, discovery ordering, MTU bounds, PCAP preservation, native connection
identity, handle reuse, stale-reply rejection, disconnect routing and injection
selection. They do not replace hardware tests of CoreBluetooth
callbacks, writes under backpressure, security negotiation, multiple devices,
service changes and reconnects. A useful report includes host/guest versions,
bundle commit, peripheral model, exact failing operation and a sanitized trace.

See [the research notes](../../Research/0_binary_patch_comparison.md#physical-bluetooth-low-energy-bridge-experimental-2026-10-29)
for patch reveal and original device-validation evidence.
