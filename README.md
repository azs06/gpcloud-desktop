# GP Cloud for Mac

An **unofficial** native macOS client for [Grameenphone GP Cloud](https://gpcloud.grameenphone.com), laid out like Google Drive, with a menu bar extra.

> **Not affiliated with, endorsed by, or supported by Grameenphone.** "GP Cloud" and "Grameenphone" belong to their owners.
> The app talks to undocumented APIs that can change at any time. Use at your own risk.

## Features

- **My Drive**: breadcrumbs, a grid view (thumbnails for photos and videos), and a list view sortable by name, date or size
- **Upload files and whole folders**: drag from Finder, ⌘U, or the + button. Multipart uploads in parallel, with retries and instant (dedup) uploads
- **Download** with progress, **Open** in the default app, **Quick Look** (Space)
- New folder, rename, move, copy, star, **Trash** (restore, delete forever, empty), search, **Recent**, **Starred**
- **Menu bar extra**: storage meter, live transfers, quick upload, recent files, Open at Login. Closing the window keeps the app running in the menu bar (turn this off under View → Show in Menu Bar)
- Keyboard shortcuts: ⌘1–4 switch sections, ⌘↑ goes up a folder, ⌫ moves to Trash, Space for Quick Look, ⌘R refreshes, ⇧⌘N makes a new folder
- Universal (Apple Silicon and Intel), macOS 14 Sonoma or later

## Install

### Homebrew

```sh
brew install --cask azs06/tap/gpcloud
```

Upgrade with `brew upgrade --cask gpcloud`. The cask clears the download quarantine, so the app opens normally.

### Manual

1. Download `GPCloud-<version>-macOS.zip` from [Releases](../../releases) and unzip it.
2. Move **GPCloud.app** to `/Applications`.
3. First launch: the app is ad-hoc signed and **not notarized**, so macOS will block a double-click. Either
   - right-click the app → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/GPCloud.app`.

## Signing in

Click **Sign in**. GP Cloud's own login page opens inside the app (phone number, password or OTP, 2FA). After you sign in, the app reads the session's access token from the web session. **The app never sees or stores your password.** GP Cloud's servers refresh the token. Sign Out (⋯ menu at the bottom of the sidebar, or the menu bar) deletes the app's GP Cloud cookies.

## Build from source

Only Command Line Tools are needed; Xcode isn't required.

```sh
./scripts/build-app.sh            # universal app → dist/GPCloud.app
ARCHS=arm64 ./scripts/build-app.sh  # faster, Apple Silicon only
./scripts/package-release.sh      # → dist/GPCloud-<version>-macOS.zip + .sha256
swift run -c release gpcloud-selftest   # offline tests for the hashing/upload math
```

> Recent Command Line Tools ship a macOS 26.5 SDK that can't import WebKit with Swift 6.3.3
> (`could not build Objective-C module 'std'`). The build script uses `MacOSX15.4.sdk` when it exists.
> Set `GPCLOUD_SDK=/path/to/sdk` to override. If you run `swift build`/`swift run` yourself and hit that error,
> prefix the command with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk`.

## How it works

[docs/API.md](docs/API.md) is the reverse-engineered protocol: the NextAuth login, every file endpoint, and the multipart upload. Each upload slice carries a SHA-256 *midstate* (`hashCtx`), plus a `proofCode` the server uses to check that the client has the file.

```
Sources/GPCloudKit/      API client + upload protocol (no UI)
  GPCloudAPI.swift         endpoints, response envelope, 401 → refresh → retry
  UploadPlanner.swift      slicing, per-slice SHA-256 midstates, proofCode, name rules
  UploadEngine.swift       create-file-meta → PUT slices to storage → complete-status
  MidstateHasher.swift     CommonCrypto SHA-256 with midstate access (~2 GB/s), self-verified
  SHA256Midstate.swift     portable fallback / reference implementation
  Downloader.swift         downloads with progress
Sources/GPCloud/         SwiftUI app: auth (WKWebView), drive model, transfers, views, menu bar
Sources/SelfTest/        offline checks
```

## Known limitations

- **Copy Public Link** and **Copy To** follow the Android app's requests but haven't been tested much. The share link's `validity` unit is a guess (7 days).
- GP Cloud doesn't allow spaces or `<>|:"*?/\` in names. Uploads replace spaces with `_` and drop the other characters. The rename and new-folder dialogs explain the rule and offer to fix the name.
- Empty (0-byte) files are rejected by the service.
- **Open at Login** needs the app in `/Applications`.

## License

[MIT](LICENSE)
