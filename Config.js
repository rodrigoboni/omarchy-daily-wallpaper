.pragma library

var DEFAULT_CONFIG = {
  enabled: true,
  intervalHours: 24,
  keepDays: 7,
  wallpaperDir: "",
  sources: ["bing", "nasa_images", "met"],
  keywords: "moon,mars,jupiter,nebula,galaxy,hubble,earth,aurora",
  metQuery: "",
  unsplashQuery: "",
  matchResolution: true,
  applyToLockScreen: true,
  notifyOnChange: true,
  nasaApiKey: "",
  unsplashAccessKey: "",
  bingMkt: "en-US"
}

var SOURCE_IDS = ["bing", "apod", "met", "nasa_images", "unsplash"]

function defaultWallpaperDir(home) {
  return String(home || "") + "/Pictures/daily-wallpapers"
}

function mergeConfig(raw, home) {
  var cfg = {}
  var src = raw && typeof raw === "object" ? raw : {}
  for (var key in DEFAULT_CONFIG) cfg[key] = DEFAULT_CONFIG[key]
  for (var k in src) {
    if (Object.prototype.hasOwnProperty.call(DEFAULT_CONFIG, k)) cfg[k] = src[k]
  }

  cfg.enabled = cfg.enabled !== false
  cfg.matchResolution = cfg.matchResolution !== false
  cfg.applyToLockScreen = cfg.applyToLockScreen !== false
  cfg.notifyOnChange = cfg.notifyOnChange !== false

  var hours = parseInt(String(cfg.intervalHours), 10)
  if (!isFinite(hours) || hours < 1) hours = 24
  if (hours > 168) hours = 168
  cfg.intervalHours = hours

  var keep = parseInt(String(cfg.keepDays), 10)
  if (!isFinite(keep) || keep < 1) keep = 7
  if (keep > 365) keep = 365
  cfg.keepDays = keep

  cfg.wallpaperDir = String(cfg.wallpaperDir || "").trim() || defaultWallpaperDir(home)
  cfg.keywords = String(cfg.keywords || "").trim()
  cfg.metQuery = String(cfg.metQuery || "").trim()
  cfg.unsplashQuery = String(cfg.unsplashQuery || "").trim()
  cfg.nasaApiKey = String(cfg.nasaApiKey || "").trim()
  cfg.unsplashAccessKey = String(cfg.unsplashAccessKey || "").trim()
  cfg.bingMkt = String(cfg.bingMkt || "en-US").trim() || "en-US"

  var sources = []
  var list = cfg.sources
  if (typeof list === "string") {
    list = list.split(",")
  }
  if (list && typeof list.length === "number") {
    for (var i = 0; i < list.length; i++) {
      var id = String(list[i] || "").trim()
      if (SOURCE_IDS.indexOf(id) >= 0 && sources.indexOf(id) < 0) sources.push(id)
    }
  }
  if (sources.length === 0) sources = DEFAULT_CONFIG.sources.slice()
  cfg.sources = sources
  return cfg
}

function parseConfigText(text, home) {
  var raw = {}
  try {
    if (text && String(text).trim() !== "") raw = JSON.parse(text)
  } catch (e) {
    raw = {}
  }
  return mergeConfig(raw, home)
}

function serializeConfig(cfg) {
  return JSON.stringify(cfg, null, 2) + "\n"
}

function parseStatusText(text) {
  try {
    if (text && String(text).trim() !== "") {
      var obj = JSON.parse(text)
      if (obj && typeof obj === "object") return obj
    }
  } catch (e) {}
  return {
    busy: false,
    lastRunAt: "",
    lastSuccessAt: "",
    lastSource: "",
    lastPath: "",
    lastError: "",
    nextRunAt: ""
  }
}

function expandHome(path, home) {
  var p = String(path || "")
  var h = String(home || "")
  if (p.indexOf("~/") === 0) return h + p.slice(1)
  if (p === "~") return h
  return p
}

// Newest-first list of attempt/run events from fetch.log (JSONL).
function parseRecentAttempts(text, limit) {
  var max = parseInt(String(limit), 10)
  if (!isFinite(max) || max < 1) max = 8
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = lines.length - 1; i >= 0 && out.length < max; i--) {
    var line = String(lines[i] || "").trim()
    if (!line) continue
    try {
      var obj = JSON.parse(line)
      if (!obj || typeof obj !== "object") continue
      var event = String(obj.event || "")
      if (event !== "attempt" && event !== "run" && event !== "reshuffle" && event !== "start") continue
      out.push({
        ts: String(obj.ts || ""),
        event: event,
        source: String(obj.source || ""),
        ok: obj.ok === true,
        error: String(obj.error || ""),
        path: String(obj.path || "")
      })
    } catch (e) {}
  }
  return out
}

function attemptSummaryLine(entry) {
  if (!entry) return ""
  if (entry.event === "start") return "run started"
  if (entry.event === "reshuffle") return "deck reshuffled"
  if (entry.event === "run") {
    if (entry.ok) return "run ok · " + (entry.source || "?")
    return "run failed · " + (entry.error || "error")
  }
  var src = entry.source || "?"
  if (entry.ok) return src + " ok"
  var err = String(entry.error || "failed")
  if (err.length > 48) err = err.substring(0, 45) + "…"
  return src + " · " + err
}
