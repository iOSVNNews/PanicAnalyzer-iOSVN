# Third-party notices

## idevice

PanicAnalyzer's optional Remote Pairing bridge links selected components from
[`jkcoxson/idevice`](https://github.com/jkcoxson/idevice), pinned in
`PairingBridge/Cargo.toml`.

Copyright (c) the idevice contributors. Licensed under the MIT License; see the
upstream repository for its complete license text.

The bridge only exposes read-only CrashReportCopyMobile operations (list and
pull). Delete, move, install and general filesystem operations are deliberately
not exported to Swift.
