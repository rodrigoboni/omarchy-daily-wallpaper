# Omarchy Daily Wallpaper

Multi-source rotating wallpaper plugin for [Omarchy](https://omarchy.org/).

Fetches wallpapers from Bing, NASA APOD, NASA Image Library, Met Museum, and Unsplash on a schedule (or on demand), with resolution filtering, local retention, and optional lock-screen sync.

## Install

```bash
omarchy plugin add https://github.com/rodrigoboni/omarchy-daily-wallpaper.git --enable
```

Then open the bar widget to configure sources, keywords, interval, and API keys (NASA / Unsplash).

## Features

- Shuffled source deck with failover and one reshuffle if the current deck fails
- Display resolution matching (Hyprland monitors)
- Configurable interval, retention, and storage folder
- Apply to desktop and lock screen via Omarchy backgrounds
- Fetch log + last-attempt summary in the panel

## Config & state

| Path | Purpose |
|------|---------|
| `~/.config/omarchy/daily-wallpaper/config.json` | Settings and API keys |
| `~/.local/state/omarchy/daily-wallpaper/fetch.log` | Attempt log |
| `~/.local/state/omarchy/daily-wallpaper/status.json` | Last / next run |
| `~/Pictures/daily-wallpapers/` | Downloaded images (default) |

## License

MIT
