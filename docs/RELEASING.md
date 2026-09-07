# Releasing SnapRescale (maintainer notes)

Requires the paid Apple Developer Program on the personal team (7XVA74UJHL)
and Xcode signed in to that Apple ID.

## GitHub download (DMG)

```sh
./Scripts/release.sh                          # hardened Release build, Developer ID signed, DMG in build/release
NOTARY_PROFILE=snaprescale ./Scripts/release.sh   # + notarise and staple
```

Without a Developer ID Application certificate the script signs ad-hoc; that
DMG is for local testing only and Gatekeeper will refuse it elsewhere. One-time
notarisation setup:

```sh
xcrun notarytool store-credentials snaprescale --apple-id <id> --team-id 7XVA74UJHL
```

## Mac App Store

```sh
./Scripts/appstore.sh          # archive (Apple Development) + export for App Store Connect → build/appstore/export/*.pkg
UPLOAD=1 ./Scripts/appstore.sh # archive + validate + upload through Xcode's account
```

`UPLOAD` must be exactly `1`. Bump `CURRENT_PROJECT_VERSION` in `project.yml`
for every upload. Listing copy and the submission checklist:
[APP-STORE.md](APP-STORE.md). Screenshots: `--window 1440x900` plus
`Scripts/flatten-screenshot.swift` (see APP-STORE.md).
