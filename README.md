# Grab

A tiny macOS app: paste a URL, click Download. It runs `yt-dlp` and `ffmpeg` under the hood.

## Setup

```bash
xcode-select --install        # once, if you don't have the Command Line Tools
brew install yt-dlp ffmpeg
cd Grab
chmod +x build.sh
./build.sh
open Grab.app
```

Requires macOS 13 or later. Drag `Grab.app` to `/Applications` if you want to keep it.

## Features

- Video (MP4, optional 1080p/720p/480p cap) or audio-only (MP3)
- Choose the destination folder (defaults to Downloads)
- Progress bar, cancel button, collapsible log, "Show in Finder"
- Single videos only (playlists are skipped on purpose)

## Notes

- Looks for `yt-dlp` and `ffmpeg` in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`.
- Keep yt-dlp current (`brew upgrade yt-dlp`) – sites change often.
- Only download content you have the right to save.
