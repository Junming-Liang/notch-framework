# Notch Framework — development slice

An independent macOS 13+ host for separately maintained process extensions. This repository is a **development prototype**, not a production extension marketplace.

## Build on macOS

```sh
swift test
bash Tools/build-app.sh
```

Build the separate `notch-extension-hello` project, then import its built fixture directory from the host's extension center. Installation starts disabled. Enabling explicitly executes trusted local code with your user privileges; it is not sandboxed.

The host owns windows and camera-exclusion geometry. Hello sends presentation data through bounded JSON-lines IPC. No dynamic libraries or extension-owned views are loaded into the host.

## Current boundaries

Production executable installation is blocked until production trust roots and platform-signing policy are configured. Signed loopback network installation is implemented for explicitly trusted local tests using a public RFC8032 vector; this key cannot authorize remote packages. A SHA-256 digest does not establish trust. There is no production signing, notarization, Pages deployment, or remote release. Test-package health checks and rollback are implemented; native execution remains pending macOS CI.

The App supports local fixture directories and signed local-HTTP test packages. Native Swift parses strict ZIP_STORED archives; the Python archive tool is separate test tooling. `bash Tools/verify-network-ci.sh` exercises the real network/install/IPC chain on macOS. The process runner manages direct children, not hostile descendants.

On a display with no hardware notch, the host does not draw a fake notch. The extension center remains usable. Hardware contour curves are approximations; public NSScreen APIs expose exclusion rectangles.

See `Docs/ACCEPTANCE.zh-CN.md` for the acceptance checklist. Licensed under MIT; see `LICENSE`. See `THIRD-PARTY-NOTICES.md` for reference and dependency boundaries.

Public GitHub Pages/raw catalogs can be browsed as explicitly unverified previews. Preview metadata never authorizes execution. Native compile and tests have not yet run in the Linux authoring environment.
