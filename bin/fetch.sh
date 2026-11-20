#!/usr/bin/env bash
# Multi-source wallpaper fetcher for Omarchy (Bing, NASA APOD, Met, NASA Images, Unsplash).
# Shuffled deck: each successful run removes that source; when empty, reshuffle.
# Requires: curl, jq. Optional: identify/magick for post-download size checks.
#
# Usage:
#   fetch.sh --config ~/.config/omarchy/daily-wallpaper/config.json \
#            [--min-width N] [--min-height N]
#   fetch.sh --config ... --purge-only
# Prints one JSON object to stdout on completion / failure / purge-only.

set -euo pipefail

CONFIG_PATH=""
MIN_WIDTH_OVERRIDE=""
MIN_HEIGHT_OVERRIDE=""
PURGE_ONLY="0"
PROTECT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --min-width)
      MIN_WIDTH_OVERRIDE="${2:-}"
      shift 2
      ;;
    --min-height)
      MIN_HEIGHT_OVERRIDE="${2:-}"
      shift 2
      ;;
    --purge-only)
      PURGE_ONLY="1"
      shift
      ;;
    --protect)
      PROTECT_PATH="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/omarchy/daily-wallpaper"
QUEUE_FILE="${STATE_DIR}/queue.json"
INDEX_FILE="${STATE_DIR}/image-index.json"
LOG_FILE="${STATE_DIR}/fetch.log"
LOG_MAX_LINES=400
WALLPAPER_DIR="${HOME}/Pictures/daily-wallpapers"
SOURCES_CSV="bing,nasa_images,met"
KEEP_DAYS="7"
KEYWORDS="moon,mars,nebula,galaxy,hubble,earth,aurora"
MET_QUERY=""
UNSPLASH_QUERY=""
MIN_WIDTH="0"
MIN_HEIGHT="0"
APPLY_LOCK="1"
NASA_API_KEY=""
UNSPLASH_ACCESS_KEY=""
BING_MKT="en-US"
BING_IDX="0"
BING_IMAGE_COUNT="8"
NASA_MAX_PAGE="10"
NASA_SEARCH_ATTEMPTS="8"
MATCH_RES="1"

if [[ -n "${CONFIG_PATH}" && -f "${CONFIG_PATH}" ]]; then
  # Config may hold API keys — keep it owner-readable only.
  chmod 600 "${CONFIG_PATH}" 2>/dev/null || true
  chmod 700 "$(dirname -- "${CONFIG_PATH}")" 2>/dev/null || true
  eval "$(jq -r '
    def s($k; $d):
      (($k | tostring) as $key
       | if has($key) and (.[$key] != null) then .[$key] else $d end);
    def b($k; $d):
      (s($k; $d) | if type == "boolean" then (if . then "1" else "0" end)
                   elif . == true or . == "true" or . == 1 or . == "1" then "1"
                   else "0" end);
    def csv($k; $d):
      (s($k; $d)
       | if type == "array" then map(tostring) | join(",")
         else tostring end);
    [
      "SOURCES_CSV=" + (csv("sources"; "bing,nasa_images,met") | @sh),
      "KEEP_DAYS=" + (s("keepDays"; 7) | tostring | @sh),
      "WALLPAPER_DIR=" + (s("wallpaperDir"; "") | tostring | @sh),
      "KEYWORDS=" + (s("keywords"; "moon,mars,nebula") | tostring | @sh),
      "MET_QUERY=" + (s("metQuery"; "") | tostring | @sh),
      "UNSPLASH_QUERY=" + (s("unsplashQuery"; "") | tostring | @sh),
      "APPLY_LOCK=" + (b("applyToLockScreen"; true) | @sh),
      "NASA_API_KEY=" + (s("nasaApiKey"; "") | tostring | @sh),
      "UNSPLASH_ACCESS_KEY=" + (s("unsplashAccessKey"; "") | tostring | @sh),
      "BING_MKT=" + (s("bingMkt"; "en-US") | tostring | @sh),
      "MATCH_RES=" + (b("matchResolution"; true) | @sh)
    ] | .[]
  ' "${CONFIG_PATH}")"
fi

if [[ -z "${WALLPAPER_DIR}" ]]; then
  WALLPAPER_DIR="${HOME}/Pictures/daily-wallpapers"
elif [[ "${WALLPAPER_DIR}" == ~* ]]; then
  WALLPAPER_DIR="${WALLPAPER_DIR/#\~/${HOME}}"
fi

if [[ -n "${MIN_WIDTH_OVERRIDE}" ]]; then
  MIN_WIDTH="${MIN_WIDTH_OVERRIDE}"
elif [[ "${MATCH_RES:-1}" != "1" ]]; then
  MIN_WIDTH="0"
fi
if [[ -n "${MIN_HEIGHT_OVERRIDE}" ]]; then
  MIN_HEIGHT="${MIN_HEIGHT_OVERRIDE}"
elif [[ "${MATCH_RES:-1}" != "1" ]]; then
  MIN_HEIGHT="0"
fi

mkdir -p "${WALLPAPER_DIR}" "${STATE_DIR}"

trim_log() {
  [[ -f "${LOG_FILE}" ]] || return 0
  local lines
  lines="$(wc -l <"${LOG_FILE}" 2>/dev/null || echo 0)"
  [[ "${lines}" =~ ^[0-9]+$ ]] || return 0
  if ((lines > LOG_MAX_LINES)); then
    tail -n "${LOG_MAX_LINES}" "${LOG_FILE}" >"${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
  fi
}

# Append one JSONL event. Never log secrets.
log_event() {
  local event="$1" source="${2:-}" ok_flag="${3:-0}" error="${4:-}" path="${5:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc \
    --arg ts "${ts}" \
    --arg event "${event}" \
    --arg source "${source}" \
    --argjson ok "$([[ "${ok_flag}" == "1" ]] && echo true || echo false)" \
    --arg error "${error}" \
    --arg path "${path}" \
    '{ts:$ts,event:$event,source:$source,ok:$ok,error:$error,path:$path}' >>"${LOG_FILE}" 2>/dev/null || true
  trim_log
}

emit() {
  jq -nc \
    --arg ok "${1}" \
    --arg source "${2:-}" \
    --arg path "${3:-}" \
    --arg error "${4:-}" \
    '{ok: ($ok == "1"), source: $source, path: $path, error: $error}'
}

fail() {
  log_event "run" "" 0 "$1" ""
  emit 0 "" "" "$1"
  exit 0
}

# URI-encode via jq, feeding the string on stdin so it never appears in jq argv
# (important for secrets such as NASA_API_KEY).
uri_encode() {
  printf '%s' "$1" | jq -rn --raw-input '@uri'
}

# Ensure dir is a real directory we own with mode 700. Never follow/trust a
# pre-existing shared location another account could have planted.
_secure_owner_dir() {
  local dir="$1" uid mode
  uid="$(id -u)"
  if [[ -L "${dir}" ]]; then
    return 1
  fi
  if [[ -e "${dir}" ]]; then
    [[ -d "${dir}" ]] || return 1
  else
    (umask 077; mkdir -p -- "${dir}") || return 1
  fi
  [[ ! -L "${dir}" && -d "${dir}" ]] || return 1
  mode="$(stat -c '%a' "${dir}" 2>/dev/null || true)"
  [[ "$(stat -c '%u' "${dir}" 2>/dev/null || true)" == "${uid}" ]] || return 1
  if [[ "${mode}" != "700" ]]; then
    chmod 700 -- "${dir}" || return 1
    mode="$(stat -c '%a' "${dir}" 2>/dev/null || true)"
    [[ "${mode}" == "700" ]] || return 1
  fi
  [[ "$(stat -c '%u' "${dir}" 2>/dev/null || true)" == "${uid}" ]] || return 1
  return 0
}

# Private parent for short-lived secret curl configs.
# Prefer XDG_RUNTIME_DIR; otherwise a HOME state path. Never shared /tmp.
curl_runtime_parent() {
  local parent
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
    # Runtime dir itself must be ours (typical /run/user/$UID).
    [[ "$(stat -c '%u' "${XDG_RUNTIME_DIR}" 2>/dev/null || true)" == "$(id -u)" ]] || return 1
    parent="${XDG_RUNTIME_DIR}/omarchy-daily-wallpaper"
  else
    parent="${XDG_STATE_HOME:-${HOME}/.local/state}/omarchy/daily-wallpaper/runtime"
  fi
  _secure_owner_dir "${parent}" || return 1
  printf '%s' "${parent}"
}

# Run curl with a temporary --config file so secrets never appear in argv.
# Usage: curl_with_config <max-time> <config-body> [extra curl args...]
# Config lives in a fresh 0700 directory we own (under XDG_RUNTIME_DIR or
# private HOME state), never in shared /tmp.
curl_with_config() {
  local max_time="$1" body="$2"
  shift 2
  local parent work cfg ec=0
  parent="$(curl_runtime_parent)" || return 1
  work="$(umask 077; mktemp -d "${parent}/curl.XXXXXX")" || return 1
  if ! _secure_owner_dir "${work}"; then
    rm -rf -- "${work}"
    return 1
  fi
  cfg="${work}/config"
  (umask 077; : >"${cfg}") || { rm -rf -- "${work}"; return 1; }
  chmod 600 -- "${cfg}" || { rm -rf -- "${work}"; return 1; }
  printf '%s\n' "${body}" >"${cfg}"
  curl_https -fsSL --max-time "${max_time}" -K "${cfg}" "$@" || ec=$?
  rm -rf -- "${work}"
  return "${ec}"
}

# HTTPS only for requests and redirects (provider URLs / CDNs).
curl_https() {
  curl --proto '=https' --proto-redir '=https' "$@"
}

require_https_url() {
  case "${1:-}" in
    https://*) return 0 ;;
    *) return 1 ;;
  esac
}

# Transfer / decode caps for wallpaper downloads (advisory hardening).
MAX_DOWNLOAD_BYTES=$((50 * 1024 * 1024))   # 50 MiB on the wire
MIN_DOWNLOAD_BYTES=2048                    # reject empty / tiny failures
MAX_DECODED_PIXELS=$((100 * 1000 * 1000))  # 100 megapixels decoded

_normalize_int() {
  local v="${1}" d="${2}"
  [[ "${v}" =~ ^[0-9]+$ ]] || v="${d}"
  echo "${v}"
}

KEEP_DAYS="$(_normalize_int "${KEEP_DAYS}" 7)"
((KEEP_DAYS < 1)) && KEEP_DAYS=1
MIN_WIDTH="$(_normalize_int "${MIN_WIDTH}" 0)"
MIN_HEIGHT="$(_normalize_int "${MIN_HEIGHT}" 0)"
BING_IMAGE_COUNT="$(_normalize_int "${BING_IMAGE_COUNT}" 8)"
((BING_IMAGE_COUNT < 1)) && BING_IMAGE_COUNT=1
((BING_IMAGE_COUNT > 8)) && BING_IMAGE_COUNT=8
BING_IDX="$(_normalize_int "${BING_IDX}" 0)"
NASA_MAX_PAGE="$(_normalize_int "${NASA_MAX_PAGE}" 10)"
NASA_SEARCH_ATTEMPTS="$(_normalize_int "${NASA_SEARCH_ATTEMPTS}" 8)"

# Met / Unsplash accept one subject string. If the user pastes a comma list
# (same style as keywords), pick one term at random each run.
pick_query_term() {
  local raw="${1:-}" fallback="${2:-landscape}"
  local -a parts=() cleaned=() p
  [[ -z "${raw}" ]] && raw="${KEYWORDS}"
  IFS=',' read -ra parts <<< "${raw}"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "${p}" ]] && cleaned+=("${p}")
  done
  if ((${#cleaned[@]} == 0)); then
    echo -n "${fallback}"
    return 0
  fi
  echo -n "${cleaned[$((RANDOM % ${#cleaned[@]}))]}"
}

MET_QUERY="$(pick_query_term "${MET_QUERY}" "landscape")"
UNSPLASH_QUERY="$(pick_query_term "${UNSPLASH_QUERY}" "landscape")"

_nasa_key_ok() {
  [[ -n "${NASA_API_KEY}" ]] || return 1
  [[ "${NASA_API_KEY}" != "DEMO_KEY" ]] || return 1
  return 0
}

_shuffle_lines() {
  if command -v shuf >/dev/null 2>&1; then
    shuf
  else
    awk 'BEGIN { srand(); } { print rand() "\t" $0 }' | sort -n | cut -f2-
  fi
}

image_dims() {
  local file="$1"
  if command -v identify >/dev/null 2>&1; then
    identify -format '%w %h' "${file}[0]" 2>/dev/null || true
  elif command -v magick >/dev/null 2>&1; then
    magick identify -format '%w %h' "${file}[0]" 2>/dev/null || true
  fi
}

image_mime() {
  local file="$1" mime=""
  if command -v file >/dev/null 2>&1; then
    mime="$(file -b --mime-type -- "${file}" 2>/dev/null || true)"
  fi
  printf '%s' "${mime}"
}

# Require a real, bounded image before apply. Enforces transfer size, image MIME,
# optional min resolution, and decoded pixel cap when identify/magick is present.
validate_downloaded_image() {
  local file="$1" size=0 mime dims w h pixels
  [[ -f "${file}" ]] || return 1
  size="$(stat -c '%s' -- "${file}" 2>/dev/null || echo 0)"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  ((size >= MIN_DOWNLOAD_BYTES)) || return 1
  ((size <= MAX_DOWNLOAD_BYTES)) || return 1

  mime="$(image_mime "${file}")"
  case "${mime}" in
    image/jpeg | image/png | image/webp | image/gif) ;;
    *) return 1 ;;
  esac

  dims="$(image_dims "${file}")"
  if [[ -n "${dims}" ]]; then
    w="${dims%% *}"
    h="${dims##* }"
    [[ "${w}" =~ ^[0-9]+$ && "${h}" =~ ^[0-9]+$ ]] || return 1
    ((w > 0 && h > 0)) || return 1
    pixels=$((w * h))
    ((pixels <= MAX_DECODED_PIXELS)) || return 1
    ((MIN_WIDTH > 0 && w < MIN_WIDTH)) && return 1
    ((MIN_HEIGHT > 0 && h < MIN_HEIGHT)) && return 1
  elif command -v identify >/dev/null 2>&1 || command -v magick >/dev/null 2>&1; then
    # Decoder present but could not read the file — treat as corrupt.
    return 1
  fi
  # Without ImageMagick: MIME + byte caps still apply; decode size cannot be checked.
  return 0
}

# --- Bing ---

fetch_bing_json() {
  curl_https -fsSL --max-time 30 \
    "https://www.bing.com/HPImageArchive.aspx?format=js&idx=${BING_IDX}&n=${BING_IMAGE_COUNT}&mkt=${BING_MKT}"
}

pick_random_urlbase() {
  jq -r --argjson r "${RANDOM}" '
    (.images // [])
    | map(select((.wp // true) != false))
    | if length == 0 then (.images // []) else . end
    | if length == 0 then empty
      else .[$r % length].urlbase
      end
  '
}

resolve_bing_image_url() {
  local path="$1" base="https://www.bing.com${path}" suf url code
  local -a candidates=()
  if ((MIN_WIDTH >= 2560 || MIN_HEIGHT >= 1440)); then
    candidates=(_UHD.jpg _1920x1080.jpg _1280x720.jpg)
  elif ((MIN_WIDTH >= 1280 || MIN_HEIGHT >= 720)); then
    candidates=(_1920x1080.jpg _UHD.jpg _1280x720.jpg)
  else
    candidates=(_UHD.jpg _1920x1080.jpg _1280x720.jpg)
  fi
  for suf in "${candidates[@]}"; do
    url="${base}${suf}"
    require_https_url "${url}" || continue
    code="$(curl_https -sS -o /dev/null -w '%{http_code}' --max-time 20 "${url}")" || true
    if [[ "${code}" == "200" ]]; then
      echo -n "${url}"
      return 0
    fi
  done
  return 1
}

try_source_bing() {
  local json path url
  json="$(fetch_bing_json)" || return 1
  path="$(pick_random_urlbase <<< "${json}")"
  [[ -n "${path}" ]] || return 1
  url="$(resolve_bing_image_url "${path}")" || return 1
  echo -n "${url}"
}

# --- NASA APOD ---

try_source_apod() {
  _nasa_key_ok || return 1
  local json url media key_enc cfg_body
  # Keep api_key out of curl argv — only inside a 0600 -K config file.
  key_enc="$(uri_encode "${NASA_API_KEY}")"
  cfg_body="$(printf 'url = "https://api.nasa.gov/planetary/apod?api_key=%s&thumbs=true"' "${key_enc}")"
  json="$(curl_with_config 30 "${cfg_body}")" || return 1
  media="$(jq -r '.media_type // "image"' <<< "${json}")"
  if [[ "${media}" == "image" ]]; then
    url="$(jq -r '(.hdurl // .url) // empty' <<< "${json}")"
  elif [[ "${media}" == "video" ]]; then
    url="$(jq -r '(.thumbnail_url // "")' <<< "${json}")"
  else
    return 1
  fi
  [[ -n "${url}" && "${url}" != "null" ]] || return 1
  require_https_url "${url}" || return 1
  echo -n "${url}"
}

# --- NASA Image Library ---

pick_random_query() {
  local -a parts=() cleaned=() p
  IFS=',' read -ra parts <<< "${KEYWORDS}"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "${p}" ]] && cleaned+=("${p}")
  done
  ((${#cleaned[@]} > 0)) || return 1
  echo -n "${cleaned[$((RANDOM % ${#cleaned[@]}))]}"
}

pick_best_asset_href() {
  # Prefer known-large assets. Missing width/height is allowed here — the
  # post-download identify check enforces MIN_WIDTH/MIN_HEIGHT. Rejecting
  # unknown sizes up front left NASA Images empty for most results.
  jq -r --argjson minw "${MIN_WIDTH}" --argjson minh "${MIN_HEIGHT}" '
    def num: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
    def has_dim($k): (.[$k] != null) and ((.[$k] | num) > 0);
    def passes:
      ((has_dim("width") | not) or ($minw == 0) or ((.width | num) >= $minw)) and
      ((has_dim("height") | not) or ($minh == 0) or ((.height | num) >= $minh));
    (.links // [])
    | map(select(.href | ascii_downcase | test("\\.(jpg|jpeg|png)$")))
    | map(select(passes))
    | if length == 0 then empty
      else
        max_by([
          (if (.href | ascii_downcase | test("~large\\.")) then 1000
           elif (.href | ascii_downcase | test("~orig\\.")) then 900
           elif (.href | ascii_downcase | test("~medium\\.")) then 800
           elif (.href | ascii_downcase | test("~small\\.")) then 400
           elif (.href | ascii_downcase | test("~thumb\\.")) then 200
           else 0 end),
          ((.size // 0) | num)
        ])
        | .href
      end
  '
}

try_source_nasa_images() {
  local attempts=0 q page url json n idx item href
  while ((attempts < NASA_SEARCH_ATTEMPTS)); do
    q="$(pick_random_query)" || return 1
    page=$((RANDOM % (NASA_MAX_PAGE + 1)))
    url="https://images-api.nasa.gov/search?q=$(uri_encode "${q}")&media_type=image&page=${page}"
    json="$(curl_https -fsSL --max-time 30 "${url}")" || {
      ((++attempts))
      continue
    }
    n="$(jq '.collection.items | length' <<< "${json}")"
    if ((n == 0)); then
      ((++attempts))
      continue
    fi
    idx=$((RANDOM % n))
    item="$(jq -c --argjson i "${idx}" '.collection.items[$i]' <<< "${json}")"
    href="$(pick_best_asset_href <<< "${item}")"
    if [[ -n "${href}" ]] && require_https_url "${href}"; then
      echo -n "${href}"
      return 0
    fi
    ((++attempts))
  done
  return 1
}

# --- Met Museum ---

try_source_met() {
  local json total n oid detail url maxpick qenc
  qenc="$(uri_encode "${MET_QUERY}")"
  json="$(curl_https -fsSL --max-time 30 "https://collectionapi.metmuseum.org/public/collection/v1/search?hasImages=true&q=${qenc}")" || return 1
  total="$(jq '.total // 0' <<< "${json}")"
  ((total > 0)) || return 1
  n="$(jq '[.objectIDs[]?] | length' <<< "${json}")"
  ((n > 0)) || return 1
  maxpick=40
  ((n > maxpick)) && n=${maxpick}
  oid="$(jq -r --argjson r "${RANDOM}" --argjson lim "${n}" '.objectIDs[0:$lim] | .[$r % length]' <<< "${json}")"
  [[ -n "${oid}" && "${oid}" != "null" ]] || return 1
  detail="$(curl_https -fsSL --max-time 30 "https://collectionapi.metmuseum.org/public/collection/v1/objects/${oid}")" || return 1
  url="$(jq -r '.primaryImage // empty' <<< "${detail}")"
  [[ -n "${url}" && "${url}" != "null" ]] || return 1
  require_https_url "${url}" || return 1
  echo -n "${url}"
}

# --- Unsplash ---

try_source_unsplash() {
  [[ -n "${UNSPLASH_ACCESS_KEY}" ]] || return 1
  local json url qenc cfg_body
  qenc="$(uri_encode "${UNSPLASH_QUERY}")"
  # Keep Client-ID out of curl argv — only inside a 0600 -K config file.
  cfg_body="$(printf 'header = "Authorization: Client-ID %s"' "${UNSPLASH_ACCESS_KEY}")"
  json="$(curl_with_config 30 "${cfg_body}" \
    "https://api.unsplash.com/photos/random?orientation=landscape&content_filter=high&query=${qenc}")" || return 1
  url="$(jq -r '.urls.raw // .urls.full // .urls.regular // empty' <<< "${json}")"
  [[ -n "${url}" && "${url}" != "null" ]] || return 1
  require_https_url "${url}" || return 1
  local w="${MIN_WIDTH}"
  ((w < 1920)) && w=3840
  case "${url}" in
    *\?*) echo -n "${url}&w=${w}&q=85" ;;
    *) echo -n "${url}?w=${w}&q=85" ;;
  esac
}

try_source_by_name() {
  case "$1" in
    bing) try_source_bing ;;
    apod) try_source_apod ;;
    met) try_source_met ;;
    nasa_images) try_source_nasa_images ;;
    unsplash) try_source_unsplash ;;
    *) return 1 ;;
  esac
}

# --- deck ---

parse_sources_csv() {
  local raw="${SOURCES_CSV}" p
  local -a parts=()
  IFS=',' read -ra parts <<< "${raw}"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "${p}" ]] && printf '%s\n' "${p}"
  done
}

eligible_sources_list() {
  local -a raw=() filtered=()
  local s
  mapfile -t raw < <(parse_sources_csv)
  if ((${#raw[@]} == 0)); then
    raw=(bing nasa_images met)
  fi
  for s in "${raw[@]}"; do
    case "${s}" in
      bing | met | nasa_images) filtered+=("${s}") ;;
      apod)
        if _nasa_key_ok; then
          filtered+=("apod")
        fi
        ;;
      unsplash)
        if [[ -n "${UNSPLASH_ACCESS_KEY}" ]]; then
          filtered+=("unsplash")
        fi
        ;;
    esac
  done
  ((${#filtered[@]} > 0)) || return 1
  printf '%s\n' "${filtered[@]}"
}

queue_load_remaining() {
  if [[ ! -f "${QUEUE_FILE}" ]]; then
    echo "[]"
    return 0
  fi
  jq -c '.remaining // []' "${QUEUE_FILE}" 2>/dev/null || echo "[]"
}

queue_save_remaining() {
  local json="$1"
  jq -nc --argjson r "${json}" '{remaining: $r}' >"${QUEUE_FILE}.tmp"
  mv "${QUEUE_FILE}.tmp" "${QUEUE_FILE}"
}

queue_reshuffle() {
  local -a list=()
  mapfile -t list < <(eligible_sources_list) || return 1
  ((${#list[@]} > 0)) || return 1
  local shuffled
  shuffled="$(printf '%s\n' "${list[@]}" | _shuffle_lines | jq -R -s -c 'split("\n") | map(select(length>0))')"
  queue_save_remaining "${shuffled}"
  echo "${shuffled}"
}

sha256_text() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

sha256_file() {
  sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
}

# Canonicalize provider URLs so ephemeral resize params don't defeat URL dedupe
# (Unsplash w=/q=, etc.). Path + host still distinguish distinct assets.
canonical_image_url() {
  local url="${1%%\?*}"
  printf '%s' "${url}"
}

index_load() {
  if [[ -f "${INDEX_FILE}" ]]; then
    jq -c 'if type == "object" then . else {} end
      | {byUrl: (.byUrl // {}), byHash: (.byHash // {})}' "${INDEX_FILE}" 2>/dev/null \
      || echo '{"byUrl":{},"byHash":{}}'
  else
    echo '{"byUrl":{},"byHash":{}}'
  fi
}

index_save() {
  local json="$1"
  jq -nc --argjson i "${json}" '$i' >"${INDEX_FILE}.tmp" 2>/dev/null \
    && mv "${INDEX_FILE}.tmp" "${INDEX_FILE}"
}

index_lookup_url() {
  local url_key="$1" path
  path="$(jq -r --arg k "${url_key}" '.byUrl[$k] // empty' <<< "$(index_load)" 2>/dev/null || true)"
  if [[ -n "${path}" && -f "${path}" ]]; then
    echo -n "${path}"
    return 0
  fi
  return 1
}

index_lookup_hash() {
  local hash="$1" path
  path="$(jq -r --arg k "${hash}" '.byHash[$k] // empty' <<< "$(index_load)" 2>/dev/null || true)"
  if [[ -n "${path}" && -f "${path}" ]]; then
    echo -n "${path}"
    return 0
  fi
  return 1
}

index_remember() {
  local url_key="$1" content_hash="$2" path="$3"
  local idx
  idx="$(index_load)"
  idx="$(jq -c --arg uk "${url_key}" --arg hk "${content_hash}" --arg p "${path}" '
    .byUrl[$uk] = $p | .byHash[$hk] = $p
  ' <<< "${idx}")"
  index_save "${idx}"
}

# Remove duplicate files (same content hash), keep one; rebuild byHash index.
# Prefer keeping a currently applied / protected path when choosing the survivor.
dedupe_library() {
  local f hash path removed=0
  local -A best=()
  local -A protected=()
  local p idx old uk up

  while IFS= read -r p; do
    [[ -n "${p}" ]] && protected["${p}"]=1
  done < <(protect_paths)

  while IFS= read -r -d '' f; do
    hash="$(sha256_file "${f}")"
    [[ -n "${hash}" ]] || continue
    path="$(readlink -f "${f}" 2>/dev/null || echo "${f}")"
    if [[ -n "${best[$hash]:-}" ]]; then
      if [[ -n "${protected[$path]+x}" ]]; then
        rm -f -- "${best[$hash]}" && ((++removed)) || true
        best["${hash}"]="${path}"
      else
        rm -f -- "${path}" && ((++removed)) || true
      fi
    else
      best["${hash}"]="${path}"
    fi
  done < <(find "${WALLPAPER_DIR}" -maxdepth 1 -type f \
    \( -name 'wp-*' -o -name 'bing-*' \) ! -name '*.part' -print0 2>/dev/null)

  idx='{"byUrl":{},"byHash":{}}'
  for hash in "${!best[@]}"; do
    path="${best[$hash]}"
    [[ -f "${path}" ]] || continue
    idx="$(jq -c --arg hk "${hash}" --arg p "${path}" '.byHash[$hk] = $p' <<< "${idx}")"
  done

  old="$(index_load)"
  while IFS= read -r uk; do
    [[ -n "${uk}" ]] || continue
    up="$(jq -r --arg k "${uk}" '.byUrl[$k] // empty' <<< "${old}")"
    up="$(readlink -f "${up}" 2>/dev/null || echo "${up}")"
    [[ -n "${up}" && -f "${up}" ]] || continue
    idx="$(jq -c --arg k "${uk}" --arg p "${up}" '.byUrl[$k] = $p' <<< "${idx}")"
  done < <(jq -r '.byUrl | keys[]?' <<< "${old}" 2>/dev/null)

  index_save "${idx}"
  ((removed > 0)) && log_event "dedupe" "" 1 "removed=${removed}" ""
  echo "${removed}"
}

current_wallpaper_path() {
  local p=""
  p="$(readlink -f "${HOME}/.local/state/omarchy/current/background" 2>/dev/null || true)"
  if [[ -z "${p}" && -f "${STATE_DIR}/status.json" ]]; then
    p="$(jq -r '.lastPath // empty' "${STATE_DIR}/status.json" 2>/dev/null || true)"
    [[ -n "${p}" ]] && p="$(readlink -f "${p}" 2>/dev/null || echo "${p}")"
  fi
  printf '%s' "${p}"
}

download_image() {
  local image_url="$1" prefix="$2"
  local base ext ext_lc stamp rand dest tmp url_key canon existing content_hash
  require_https_url "${image_url}" || return 1
  canon="$(canonical_image_url "${image_url}")"
  url_key="$(sha256_text "${canon}")"

  if existing="$(index_lookup_url "${url_key}")"; then
    if validate_downloaded_image "${existing}"; then
      echo -n "${existing}"
      return 0
    fi
  fi

  base="${canon}"
  ext="${base##*.}"
  ext_lc="$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')"
  case "${ext_lc}" in
    jpg | jpeg | png | webp | gif) ;;
    *) ext_lc="jpg" ;;
  esac
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  rand="$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")"
  dest="${WALLPAPER_DIR}/wp-${prefix}-${stamp}-${rand}.${ext_lc}"
  tmp="${dest}.part"
  rm -f "${tmp}"
  # Fail closed on HTTP errors, oversized Content-Length, and cleartext redirects.
  if ! curl_https -fsSL --max-time 120 --max-filesize "${MAX_DOWNLOAD_BYTES}" \
      "${image_url}" -o "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if [[ ! -f "${tmp}" ]] || ! validate_downloaded_image "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi

  content_hash="$(sha256_file "${tmp}")"
  if [[ -n "${content_hash}" ]] && existing="$(index_lookup_hash "${content_hash}")"; then
    rm -f "${tmp}"
    index_remember "${url_key}" "${content_hash}" "${existing}"
    echo -n "${existing}"
    return 0
  fi

  mv "${tmp}" "${dest}"
  if [[ -n "${content_hash}" ]]; then
    index_remember "${url_key}" "${content_hash}" "${dest}"
  fi
  echo -n "${dest}"
}

apply_wallpaper() {
  local dest="$1"
  if [[ "${APPLY_LOCK}" == "1" ]]; then
    omarchy theme bg set "${dest}" >/dev/null
  else
    omarchy-shell -q background set "${dest}" >/dev/null || omarchy theme bg set "${dest}" >/dev/null
  fi
}

# Collect absolute paths that must survive retention (plugin lastPath, --protect,
# and Omarchy's currently applied background if it lives in WALLPAPER_DIR).
protect_paths() {
  local -a paths=()
  local p
  if [[ -n "${PROTECT_PATH}" ]]; then
    paths+=("${PROTECT_PATH}")
  fi
  if [[ -f "${STATE_DIR}/status.json" ]]; then
    p="$(jq -r '.lastPath // empty' "${STATE_DIR}/status.json" 2>/dev/null || true)"
    [[ -n "${p}" ]] && paths+=("${p}")
  fi
  # Omarchy points ~/.local/state/omarchy/current/background at the active file.
  # An older download may still be selected via the background switcher.
  p="$(readlink -f "${HOME}/.local/state/omarchy/current/background" 2>/dev/null || true)"
  [[ -n "${p}" ]] && paths+=("${p}")

  local -A seen=()
  for p in "${paths[@]}"; do
    p="$(readlink -f "${p}" 2>/dev/null || echo "${p}")"
    [[ -n "${p}" ]] || continue
    [[ -n "${seen[$p]+x}" ]] && continue
    seen["${p}"]=1
    printf '%s\n' "${p}"
  done
}

# Delete wallpapers older than KEEP_DAYS (minute-accurate). Never remove protected paths.
prune_old() {
  local mins removed=0
  local -A protect=()
  local p f abs
  mins=$((KEEP_DAYS * 24 * 60))
  ((mins < 1)) && mins=1
  while IFS= read -r p; do
    [[ -n "${p}" ]] && protect["${p}"]=1
  done < <(protect_paths)

  while IFS= read -r -d '' f; do
    abs="$(readlink -f "${f}" 2>/dev/null || echo "${f}")"
    if [[ -n "${protect[$abs]+x}" ]]; then
      continue
    fi
    rm -f "${f}" && ((++removed)) || true
  done < <(find "${WALLPAPER_DIR}" -maxdepth 1 -type f \
    \( -name 'wp-*' -o -name 'bing-*' \) \
    -mmin "+${mins}" -print0 2>/dev/null)
  log_event "purge" "" 1 "removed=${removed} keepDays=${KEEP_DAYS}" ""
  echo "${removed}"
}

# Sets DECK_IDX / DECK_SRC / DECK_DEST / DECK_REM on success.
try_deck() {
  local remaining_json="$1"
  local -a remaining_arr=()
  local i src url dest="" cur cur_hash dest_hash dest_abs
  DECK_IDX=-1
  DECK_SRC=""
  DECK_DEST=""
  DECK_REM="${remaining_json}"
  cur="$(current_wallpaper_path)"
  cur_hash=""
  [[ -n "${cur}" && -f "${cur}" ]] && cur_hash="$(sha256_file "${cur}")"
  mapfile -t remaining_arr < <(jq -r '.[]' <<< "${remaining_json}")
  ((${#remaining_arr[@]} > 0)) || return 1
  for i in "${!remaining_arr[@]}"; do
    src="${remaining_arr[i]}"
    if url="$(try_source_by_name "${src}")"; then
      if dest="$(download_image "${url}" "${src}")"; then
        dest_abs="$(readlink -f "${dest}" 2>/dev/null || echo "${dest}")"
        # Same file or same bytes as the active wallpaper — try another source.
        if [[ -n "${cur}" && "${dest_abs}" == "${cur}" ]]; then
          log_event "attempt" "${src}" 0 "duplicate of current wallpaper" "${dest}"
          continue
        fi
        if [[ -n "${cur_hash}" ]]; then
          dest_hash="$(sha256_file "${dest}")"
          if [[ -n "${dest_hash}" && "${dest_hash}" == "${cur_hash}" ]]; then
            log_event "attempt" "${src}" 0 "duplicate of current wallpaper" "${dest}"
            continue
          fi
        fi
        log_event "attempt" "${src}" 1 "" "${dest}"
        DECK_IDX="${i}"
        DECK_SRC="${src}"
        DECK_DEST="${dest}"
        return 0
      fi
      log_event "attempt" "${src}" 0 "download failed or image too small" ""
    else
      log_event "attempt" "${src}" 0 "source unavailable" ""
    fi
  done
  return 1
}

main() {
  local remaining_json n new_rem removed

  if [[ "${PURGE_ONLY}" == "1" ]]; then
    removed="$(prune_old)"
    dedupe_library >/dev/null || true
    emit 1 "" "" "purged=${removed}"
    exit 0
  fi

  log_event "start" "" 1 "" ""
  # Retention + content dedupe (builds image-index for URL/hash lookups).
  prune_old >/dev/null || true
  dedupe_library >/dev/null || true

  remaining_json="$(queue_load_remaining)"
  n="$(jq 'length' <<< "${remaining_json}")"
  if ((n == 0)); then
    remaining_json="$(queue_reshuffle)" || fail "no eligible sources (check API keys / source list)"
    log_event "reshuffle" "" 1 "empty deck" ""
  fi

  if ! try_deck "${remaining_json}"; then
    # Remaining entries can all be broken this cycle (e.g. Met 410 + APOD
    # timeout). Reshuffle once so Change now can still use healthy sources.
    remaining_json="$(queue_reshuffle)" || fail "no eligible sources (check API keys / source list)"
    log_event "reshuffle" "" 1 "deck exhausted" ""
    if ! try_deck "${remaining_json}"; then
      fail "all sources failed (APIs down, bad keys, or no image large enough)"
    fi
  fi

  apply_wallpaper "${DECK_DEST}"
  PROTECT_PATH="${DECK_DEST}"
  prune_old >/dev/null || true
  new_rem="$(jq -c --argjson i "${DECK_IDX}" 'del(.[$i])' <<< "${DECK_REM}")"
  queue_save_remaining "${new_rem}"
  log_event "run" "${DECK_SRC}" 1 "" "${DECK_DEST}"
  emit 1 "${DECK_SRC}" "${DECK_DEST}" ""
}

main "$@"
