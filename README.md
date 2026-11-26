# Omarchy Daily Wallpaper

Multi-source rotating wallpaper plugin for [Omarchy](https://omarchy.org/).

Fetches wallpapers from Bing, NASA APOD, NASA Image Library, Met Museum, and Unsplash on a schedule (or on demand), with resolution filtering, local retention, OS-aware deferrals, and optional lock-screen sync.

Plugin id: `rodrigoboni.daily-wallpaper`  
Marketplace: [Daily Wallpaper on plugins.omarchy.org](https://plugins.omarchy.org/plugin.html?id=rodrigoboni.daily-wallpaper)

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
- HTTPS-only image URLs/redirects; download size and decoded-pixel caps before applying a wallpaper; API JSON responses capped at 4 MiB
- Dedupes stored wallpapers by URL and content hash (no repeated downloads of the same image). Bing keeps `?id=` (image identity lives in the query string); Unsplash/NASA/Met/APOD strip resize/tracking query params so the same asset is not stored twice.

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
| `unsplashQuery` | `""` | Unsplash query pool (comma list). Each fetch OR-joins a random subset of up to 3 terms (long OR chains often 404 on Unsplash). |
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

Keys stay only in `config.json` on this machine (directory mode `700`, file mode `600`). They are never written to the fetch log, never returned by IPC `status` (shown as `(set)`), and are passed to curl through a temporary mode-`0600` `--config` file in a fresh owner-only `0700` directory under `$XDG_RUNTIME_DIR` (or private HOME state if unset) — never shared `/tmp`. That directory is refused unless owned by the current user with mode `700`. URI-encoding also feeds secrets to `jq` on stdin (not `--arg`) so they never land in helper-process argv either.

### API keys (NASA / Unsplash)

Bing, Met, and NASA Images need no key. Enable **NASA APOD** and/or **Unsplash** in the panel, then paste keys into the matching fields (or set `nasaApiKey` / `unsplashAccessKey` in `config.json`).

#### NASA API key (for APOD)

1. Open [api.nasa.gov](https://api.nasa.gov/).
2. Fill **Generate API Key** (name, email, optional use description) and submit.
3. Copy the key from the confirmation page or the email NASA sends.
4. Paste it into the panel’s **NASA API key** field.

Do **not** use `DEMO_KEY` — the plugin rejects it (shared demo quota is too low for wallpaper rotation).

#### Unsplash access key

1. Create / sign in at [unsplash.com](https://unsplash.com/).
2. Open [Your applications](https://unsplash.com/oauth/applications) → **New Application**.
3. Accept the API terms, name the app (e.g. `omarchy-daily-wallpaper`), create it.
4. Open the app and copy the **Access Key** (not the Secret Key).
5. Paste it into the panel’s **Unsplash access key** field.

Demo / public “Client-ID” samples from Unsplash docs are not suitable; use a key from your own application. Respect [Unsplash API guidelines](https://help.unsplash.com/en/articles/2511245-unsplash-api-guidelines) (attribution is handled by Unsplash’s terms for API use; don’t hotlink without following their rules).

## State files

| Path | Purpose |
|------|---------|
| `~/.local/state/omarchy/daily-wallpaper/status.json` | Last / next run, result, skip reason, retry count |
| `~/.local/state/omarchy/daily-wallpaper/fetch.log` | JSONL attempt / run / purge events |
| `~/.local/state/omarchy/daily-wallpaper/queue.json` | Remaining shuffled source deck |
| `~/.local/state/omarchy/daily-wallpaper/image-index.json` | URL / content-hash → local file map for dedupe |

## Dependencies

Required (usually already present on Omarchy):

- `bash`, `curl`, `jq`
- Omarchy CLI (`omarchy theme bg set`, `omarchy-shell`)
- `hyprctl` (resolution matching + DPMS checks)
- `gdbus` (logind `PrepareForSleep` monitoring)

Optional:

- ImageMagick `identify` / `magick` for resolution matching and decoded-pixel caps (MIME/`file` + byte caps still apply without it)
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

1. `Service` schedules the next run from `lastSuccessAt + intervalHours` (or ~5s if that time is already past — catch-up after reboot/sleep), or a short first-run delay (~15s).
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

`--purge-only` deletes wallpapers older than `keepDays` (minute-accurate `-mmin`) and never removes `--protect`, `status.lastPath`, or Omarchy’s currently applied background (`~/.local/state/omarchy/current/background`). Still prints JSON (`error` may carry `purged=N`).

Log events (`fetch.log` JSONL): `start`, `attempt`, `reshuffle`, `run`, `purge`. Secrets are never logged.

Deck state: `queue.json` → `{ "remaining": ["unsplash","bing",…] }`. Empty → reshuffle from eligible configured sources.

Image downloads require `https://` URLs, use `--proto '=https' --proto-redir '=https'`, enforce `--max-filesize` / on-disk byte caps (2 KiB–50 MiB), require an image MIME type, and (when ImageMagick is available) cap decoded pixels at 100 MP and honor `--min-width` / `--min-height`. Failed or invalid downloads never reach `apply_wallpaper`.

API / metadata responses (Bing, NASA, Met, Unsplash) are also bounded: written to a private temp file with `--max-filesize` and a hard 4 MiB on-disk cap before being read into the shell — never an uncapped stream into a variable.

### Secrets and curl

NASA and Unsplash credentials are written only into a temporary curl `--config` (`-K`) file with mode `0600` inside a fresh owner-verified `0700` directory under `$XDG_RUNTIME_DIR/omarchy-daily-wallpaper/` (HOME state fallback; never shared `/tmp`), then deleted. Do not put API keys in curl argv (`-H`, URL query, etc.). Config containing keys is kept at mode `600`.

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
