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

## Sandbox checks (release gate)

SwiftPM tests run unsandboxed, so saving, exporting and folder grants must be
checked in the sandboxed, hardened build before every upload that touches them
(`Scripts/build-xcode.sh Release`), on the test VM rather than next to an
installed copy, which shares its container. Use a disposable folder of test
images. After each step no staged file may be left: nothing named
`.name.UUID.tmp` next to the outputs, and nothing inside a volume's
`.TemporaryItems` (the empty folders themselves are the system's).

1. **Save As…** to a new name, then over an existing file (confirm Replace):
   on the internal disk and on an external or disk-image volume.
2. **Inspector Export… and Export All…** to the same two places, new and
   existing names; an export to a read-only volume shows an error.
3. **Save next to the original without asking** (Settings): the first save
   asks for the folder, the second does not and writes `_2`; quit, relaunch,
   save again with no prompt.
4. The same on an **exFAT disk image** (`hdiutil create -fs ExFAT`), which has
   no exclusive rename: the second save still writes `_2`.
5. In the Allow panel, **choose the parent folder**: the save succeeds, and
   later saves in that folder or its subfolders do not ask again; a sibling
   whose name only starts the same (`Pictures` vs `PicturesX`) still asks.
6. **Move or rename** a granted folder and save there: the grant is used or
   asked for once, never refused silently.
7. Settings ▸ **Forget All**, then save: asks again.
8. With a stored grant, a save that fails for another reason (a full disk
   image): one error alert, no second Allow panel.
9. **Save & Quit** from Open With on a large image writes, reveals and quits;
   Open With on a second image while it is still saving (after the panel has
   closed) keeps the app open on that image.

| Date | Build | macOS | Result |
|---|---|---|---|
