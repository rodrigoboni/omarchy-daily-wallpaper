# Omarchy Daily Wallpaper

Multi-source rotating wallpaper plugin for [Omarchy](https://omarchy.org/).

Fetches wallpapers from Bing, NASA APOD, NASA Image Library, Met Museum, and Unsplash on a schedule (or on demand), with resolution filtering, local retention, OS-aware deferrals, and optional lock-screen sync.

Plugin id: `rodrigoboni.daily-wallpaper`  
Marketplace: [plugins.omarchy.org](https://plugins.omarchy.org/publish.html)

## Install

```bash
omarchy plugin add https://github.com/rodrigoboni/omarchy-daily-wallpaper.git --enable
```

Open the bar widget (wallpaper icon) to configure sources, keywords, interval, storage folder, battery pause, and API keys (NASA / Unsplash when those sources are enabled).

## Remove

```bash
omarchy plugin disable rodrigoboni.daily-wallpaper
omarchy plugin remove rodrigoboni.daily-wallpaper --yes
```

This removes the plugin code under `~/.config/omarchy/plugins/`. It does **not** delete your settings, logs, or downloaded images:

| Path | What it is |
|------|------------|
| `~/.config/omarchy/daily-wallpaper/config.json` | Settings and API keys |
| `~/.local/state/omarchy/daily-wallpaper/` | Status, deck queue, fetch log |
| `~/Pictures/daily-wallpapers/` | Downloaded images (default storage folder) |

Remove those manually for a full cleanup.

## Bar widget

| Input | Action |
|-------|--------|
| Left click | Open settings panel |
| Right click | Change wallpaper now |
| Middle click | Open storage folder |

Optional bar setting **Show source label** shows the last source next to the icon.

## Features

- Shuffled source deck with failover and one reshuffle if the current deck fails
- Bounded retries after a full deck failure (3 attempts, backoff 5 / 15 / 30 minutes), then back to the normal interval
- Display resolution matching (Hyprland monitors)
- Retention purge that keeps only files within `keepDays` (minute-accurate; never deletes the current wallpaper)
- Skips **scheduled** changes while the display is off (DPMS), while the system is suspending/suspended, or (optionally) while on battery
- **Change now** always runs (bypasses those skip gates)
- Apply to desktop and lock screen via Omarchy backgrounds
- Panel status summary (result, source, time, next run, skip/retry hints); full JSONL via **Open log**

## Config reference

File: `~/.config/omarchy/daily-wallpaper/config.json`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Auto-rotate on the interval |
| `intervalHours` | `24` | Hours between successful scheduled changes (1–168) |
| `keepDays` | `7` | Delete local wallpapers older than this many days (1–365) |
| `wallpaperDir` | `~/Pictures/daily-wallpapers` | Download / storage folder |
| `sources` | `["bing","nasa_images","met"]` | Enabled source ids (see below) |
| `keywords` | (space/astronomy list) | Comma-separated subjects for NASA Images; also default Met/Unsplash term pool |
| `metQuery` | `""` | Met search string (or comma list → one term picked at random) |
| `unsplashQuery` | `""` | Unsplash query (same comma-list behavior) |
| `matchResolution` | `true` | Prefer images at least as large as the biggest monitor |
| `applyToLockScreen` | `true` | Set Omarchy lock/desktop background together |
| `notifyOnChange` | `true` | Desktop notification after a successful change |
| `pauseOnBattery` | `false` | Skip scheduled changes while on battery |
| `nasaApiKey` | `""` | Required for `apod` (not `DEMO_KEY`) |
| `unsplashAccessKey` | `""` | Required for `unsplash` |
| `bingMkt` | `"en-US"` | Bing market locale |

### Sources

| Id | Needs key | Notes |
|----|-----------|-------|
| `bing` | no | Daily Bing images |
| `nasa_images` | no | NASA Image Library search via `keywords` |
| `met` | no | Met Museum collection API |
| `apod` | NASA | Astronomy Picture of the Day |
| `unsplash` | Unsplash | Random landscape photo |

Keys stay only in `config.json` on this machine. They are never written to the fetch log, never returned by IPC `status` (shown as `(set)`), and are passed to curl through a temporary mode-`0600` `--config` file so they do not appear on the process command line.

NASA key: https://api.nasa.gov/  
Unsplash access key: https://unsplash.com/oauth/applications

## State files

| Path | Purpose |
|------|---------|
| `~/.local/state/omarchy/daily-wallpaper/status.json` | Last / next run, result, skip reason, retry count |
| `~/.local/state/omarchy/daily-wallpaper/fetch.log` | JSONL attempt / run / purge events |
| `~/.local/state/omarchy/daily-wallpaper/queue.json` | Remaining shuffled source deck |

## Dependencies

Required (usually already present on Omarchy):

- `bash`, `curl`, `jq`
- Omarchy CLI (`omarchy theme bg set`, `omarchy-shell`)
- `hyprctl` (resolution matching + DPMS checks)
- `gdbus` (logind `PrepareForSleep` monitoring)

Optional:

- ImageMagick `identify` / `magick` for post-download size checks
- NASA / Unsplash API keys for those sources

Network access is used only to fetch wallpaper metadata/images from the configured sources.

---

## Developer notes

### Layout

```
rodrigoboni.daily-wallpaper/
  manifest.json      # plugin id, kinds, bar-widget schema
  Service.qml        # always-on scheduler, gates, IPC, fetch orchestration
  BarWidget.qml      # bar icon + panel loader
  Panel.qml          # settings UI
  Config.js          # defaults, merge/parse, status helpers, retry backoff
  bin/fetch.sh       # source fetchers, deck, download, apply, purge
  i18n/en.json
  i18n/pt-BR.json
```

`keepLoaded: true` keeps `Service.qml` running so the schedule continues without the panel open.

### Runtime flow

1. `Service` schedules the next run from `lastSuccessAt + intervalHours`, or a short first-run delay.
2. On fire (scheduled only): check sleep flag, DPMS via `hyprctl monitors -j`, optional `UPower.onBattery`.
3. If blocked → set `status.skipReason`, poll ~60s / on resume / on AC restore, then retry when due.
4. Otherwise: resolve monitor minimums → `bin/fetch.sh --config … --min-width … --min-height … --protect <lastPath>`.
5. `fetch.sh` purges overdue files, walks the shuffled deck (reshuffle once if exhausted), downloads, applies wallpaper, purges again protecting the new file, prints one JSON object to stdout.
6. On success → reset `retryCount`, schedule normal interval. On full-deck failure → increment `retryCount` (max 3) with backoff 5/15/30 minutes, then fall back to the normal interval.

**Change now** sets a force flag and skips the OS gates.

### `fetch.sh` contract

```bash
bin/fetch.sh --config ~/.config/omarchy/daily-wallpaper/config.json \
  [--min-width N] [--min-height N] [--protect PATH] [--purge-only]
```

Stdout (single JSON object):

```json
{ "ok": true, "source": "bing", "path": "/…/wp-bing-….jpg", "error": "" }
```

`--purge-only` deletes wallpapers older than `keepDays` (minute-accurate `-mmin`) and never removes `--protect` / `status.lastPath`. Still prints JSON (`error` may carry `purged=N`).

Log events (`fetch.log` JSONL): `start`, `attempt`, `reshuffle`, `run`, `purge`. Secrets are never logged.

Deck state: `queue.json` → `{ "remaining": ["unsplash","bing",…] }`. Empty → reshuffle from eligible configured sources.

### Secrets and curl

NASA and Unsplash credentials are written only into a temporary curl `--config` (`-K`) file with mode `0600`, then deleted. Do not put API keys in curl argv (`-H`, URL query, etc.).

### IPC

Target: `rodrigoboni.daily-wallpaper`

| Method | Effect |
|--------|--------|
| `change` / `refresh` | Change now |
| `toggle` | Enable/disable auto-rotate |
| `status` | JSON snapshot (keys redacted) |
| `openFolder` | Open storage folder |
| `openLog` | Open fetch log in Omarchy editor |
| `purge` | Run retention purge only |

### Adding a source

1. Implement `try_source_<name>` in `bin/fetch.sh` and wire it in `try_source_by_name` / `eligible_sources_list`.
2. Add the id to `SOURCE_IDS` / defaults in `Config.js`.
3. Add a panel option in `Panel.qml` `sourceOptions` and labels in `i18n/*.json`.

### Local checks

```bash
# Retention only
bash bin/fetch.sh --config ~/.config/omarchy/daily-wallpaper/config.json --purge-only

# One fetch (will change wallpaper)
bash bin/fetch.sh --config ~/.config/omarchy/daily-wallpaper/config.json --min-width 1920 --min-height 1080

# Confirm keys are not on curl cmdline while a keyed source runs:
#   watch -n0.2 'ps eww -C curl | grep -E "nasa|unsplash|Client-ID|api_key" || true'

# Deferral: hyprctl dispatch dpms off   → scheduled runs should skip
# Battery: enable "Pause on battery" in the panel while unplugged
```

## License

MIT
