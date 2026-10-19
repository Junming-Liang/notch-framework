# Reference and dependency notices

The project source is licensed under the MIT License in `LICENSE`. This initial snapshot contains no vendored third-party implementation or copied source from codex-notch-meter or vga-aram-helper. No existing third-party copyright notices were removed.

## Public cryptographic test vector

The Ed25519 seed and public-key constants used by `NotchNetworkSmoke` and its tests are public test data from RFC 8032, section 7.1, TEST 1, by Simon Josefsson and Ilari Liusvaara:
https://www.rfc-editor.org/rfc/rfc8032.html#section-7.1

These constants are deliberately public fixtures, not credentials or production publisher identities. The generated JSON signature fixture was produced locally from this test seed. No RFC implementation code or prose is bundled. RFC material retains its own applicable rights and notices; this project's MIT license does not relicense the RFC.

## External tools and platform frameworks

Apple Foundation, AppKit, SwiftUI and CryptoKit, the Swift toolchain, Python, and GitHub Actions are external build/runtime tools, not vendored components. They retain their respective licenses and terms. The CI references `actions/checkout` by a pinned revision; its source is not included in this repository. Consult its MIT license at https://github.com/actions/checkout/blob/main/LICENSE when redistributing that action.

This project license does not grant rights to third-party services, branding, certificates, or other separately distributed software.
