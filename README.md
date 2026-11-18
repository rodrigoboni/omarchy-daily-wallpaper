# Omarchy Daily Wallpaper

Multi-source rotating wallpaper plugin for [Omarchy](https://omarchy.org/).

Fetches wallpapers from Bing, NASA APOD, NASA Image Library, Met Museum, and Unsplash on a schedule (or on demand), with resolution filtering, local retention, and optional lock-screen sync.

Marketplace listing: submit via [plugins.omarchy.org](https://plugins.omarchy.org/publish.html) (plugin id `rodrigoboni.daily-wallpaper`).

## Install

```bash
omarchy plugin add https://github.com/rodrigoboni/omarchy-daily-wallpaper.git --enable
```

Then open the bar widget (wallpaper icon) to configure sources, keywords, interval, storage folder, and API keys (NASA / Unsplash when those sources are enabled).

## Remove

```bash
omarchy plugin disable rodrigoboni.daily-wallpaper
omarchy plugin remove rodrigoboni.daily-wallpaper --yes
```

This removes the plugin code under `~/.config/omarchy/plugins/`. It does **not** delete your settings, logs, or downloaded images:

- `~/.config/omarchy/daily-wallpaper/config.json`
- `~/.local/state/omarchy/daily-wallpaper/`
- `~/Pictures/daily-wallpapers/` (default storage folder)

Remove those manually if you want a full cleanup.

## Features

- Shuffled source deck with failover and one reshuffle if the current deck fails
- Display resolution matching (Hyprland monitors)
- Configurable interval, retention, and storage folder
- Apply to desktop and lock screen via Omarchy backgrounds
- Fetch log + last-attempt summary in the panel (`Open log`)

## Config & state

| Path | Purpose |
|------|---------|
| `~/.config/omarchy/daily-wallpaper/config.json` | Settings and API keys |
| `~/.local/state/omarchy/daily-wallpaper/fetch.log` | Attempt log |
| `~/.local/state/omarchy/daily-wallpaper/status.json` | Last / next run |
| `~/Pictures/daily-wallpapers/` | Downloaded images (default) |

## Dependencies

Required on the host (usually already present on Omarchy):

- `bash`, `curl`, `jq`
- Omarchy CLI (`omarchy theme bg set`, `omarchy-shell`)
- `hyprctl` (for resolution matching)

Optional:

- ImageMagick `identify` / `magick` for post-download size checks
- NASA API key for APOD (`https://api.nasa.gov/`)
- Unsplash Access Key for Unsplash (`https://unsplash.com/oauth/applications`)

Network access is used only to fetch wallpaper metadata/images from the configured sources.

## License

MIT
