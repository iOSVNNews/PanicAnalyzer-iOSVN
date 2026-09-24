# PanicAnalyzer

An iOS app that reads `panic-full`, `.ips` and `.crash` logs and points to the
component most likely at fault. Made by iOSVN for iPhone repair technicians.

## Download

Latest builds are on the [Releases page](../../releases/latest).

| File | Install with |
|---|---|
| [PanicAnalyzer-unsigned.ipa](../../releases/latest/download/PanicAnalyzer-unsigned.ipa) | Your own signing (ESign, Sideloadly, AltStore…) |
| [PanicAnalyzer-TrollStore.tipa](../../releases/latest/download/PanicAnalyzer-TrollStore.tipa) | TrollStore |
| [PanicAnalyzer-rootless.deb](../../releases/latest/download/PanicAnalyzer-rootless.deb) | Sileo/Zebra, rootless jailbreak |
| [PanicAnalyzer-rootful.deb](../../releases/latest/download/PanicAnalyzer-rootful.deb) | Sileo/Zebra, rootful jailbreak |

Remove any IPA install with the same bundle ID before installing the TIPA or DEB.

## Features

- **Severity:** each panic is rated *Critical* (hardware signs: missing SMC
  sensors, I2C bus hangs, storage errors, SoC overheating), *Watch* (watchdog
  timeouts, sleep/wake hangs, a single kernel panic) or *Ignore* (Jetsam,
  third-party app crashes).
- **Suspected part:** missing SMC sensors and I2C device names are mapped to
  real components, each with a confidence level.
- **Repeat detection:** panics with the same cause are grouped with their
  frequency.
- **Parts tab:** reads the display and battery authentication results that
  iOS itself publishes in the IORegistry, over the pairing connection.
- **Clean reports:** exported reports have serials and UDIDs removed.
- **Share Sheet import:** share logs straight from *Analytics Data* in Settings.
- **Rules update** from this repository without reinstalling the app.
- Vietnamese, English and Chinese interface.

## Reading logs automatically (no jailbreak)

iOS 17.4 or later, with LocalDevVPN (device IP `10.7.0.1`):

1. Export a pairing file with iLoader, then in the app use
   **Settings › Import pairing file manually**, or copy `pairingFile.plist` into
   *Files › On My iPhone › PanicAnalyzer*.
   On iOS 27 you can pair on the device instead: tap **Pair this device**,
   choose *PanicAnalyzer* in *Settings › Privacy & Security › Developer* and
   enter the PIN.
2. Turn on LocalDevVPN and tap **Auto-scan system logs**.

The app only reads the CrashReporter folder (`com.apple.crashreportcopymobile`)
and, for the Parts tab, IORegistry through `diagnostics_relay`; it cannot browse
the rest of `/var`.
Pairing records stay in the app's protected storage and are excluded from
backups. TrollStore and jailbreak builds read the log folders directly and
need no pairing.

## Diagnostic rules

The rules live in `assets/`, separate from the code:

| File | Contents |
|---|---|
| `panic_rules.json` | Panic signatures and severity |
| `i2c_rules.json` | I2C addresses per bus and model |
| `sensor_database.json` | SMC sensor codes → part names |
| `model_database.json` | Model identifiers → marketing names |

Sources: Apple's xnu source, public panic logs from Apple forums, and iFixit.
Unverified rules are marked in their `source` field and rated low confidence.
Logs the app cannot identify can be sent to [@longdzqua](https://t.me/longdzqua)
on Telegram.

## Building

Requires macOS, Xcode 16+, XcodeGen and Rust:

```bash
brew install xcodegen
rustup target add aarch64-apple-ios
bash PairingBridge/build-xcframework.sh
xcodegen generate
open PanicAnalyzer.xcodeproj
```

## License

[GPL-3.0](LICENSE). The pairing bridge uses the MIT-licensed
[`jkcoxson/idevice`](https://github.com/jkcoxson/idevice); see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Logs are analysed on the
device and are only sent anywhere if you share them.
