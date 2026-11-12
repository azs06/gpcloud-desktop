# Changelog

## 1.0.0 — 2026-11-12

First release.

- Sign in through GP Cloud's own web login, shown inside the app. The app never handles your password.
- Browse My Drive in a grid (with thumbnails) or a list. Recent, Starred, Trash, and search.
- Upload files and whole folders by drag-and-drop or the Upload button, using the multipart protocol with retries, parallel slices and instant (dedup) uploads.
- Download with progress, Open in the default app, and Quick Look.
- New folder, rename, move, copy, star, Trash (restore, delete forever, empty).
- Menu bar extra: storage meter, live transfers, quick upload, recent files, Open at Login.
- Universal app for Apple Silicon and Intel, macOS 14 or later.
- Install with Homebrew: `brew install --cask azs06/tap/gpcloud`.
