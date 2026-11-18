import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Config.js" as Config

// Always-on half: schedules wallpaper rotation and exposes IPC for Change now.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/daily-wallpaper/config.json"
  readonly property string statusPath: home + "/.local/state/omarchy/daily-wallpaper/status.json"
  readonly property string logPath: home + "/.local/state/omarchy/daily-wallpaper/fetch.log"
  readonly property string stateDir: home + "/.local/state/omarchy/daily-wallpaper"

  readonly property string sourceDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") !== 0) return ""
    try { url = decodeURIComponent(url.substring(7)) } catch (e) { return "" }
    return url.replace(/\/$/, "")
  }
  readonly property string fetchScript: sourceDir + "/bin/fetch.sh"

  property var config: Config.mergeConfig({}, home)
  property var status: Config.parseStatusText("")
  property var recentAttempts: []
  property bool configReady: false
  property bool fetchQueued: false

  readonly property bool enabled: config.enabled === true
  readonly property bool busy: status.busy === true || fetchProc.running
  readonly property string lastSource: String(status.lastSource || "")
  readonly property string lastPath: String(status.lastPath || "")
  readonly property string lastError: String(status.lastError || "")
  readonly property string lastSuccessAt: String(status.lastSuccessAt || "")
  readonly property string nextRunAt: String(status.nextRunAt || "")

  function refreshLog() {
    logFile.reload()
  }

  function applyLogText(text) {
    recentAttempts = Config.parseRecentAttempts(text, 8)
  }

  function ensureDirs() {
    Quickshell.execDetached(["mkdir", "-p",
      home + "/.config/omarchy/daily-wallpaper",
      stateDir,
      Config.expandHome(config.wallpaperDir, home)
    ])
  }

  function writeStatus(patch) {
    var next = {}
    for (var k in status) next[k] = status[k]
    for (var p in patch) next[p] = patch[p]
    status = next
    statusFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function saveConfig(nextCfg) {
    config = Config.mergeConfig(nextCfg, home)
    configFile.setText(Config.serializeConfig(config))
    scheduleNext()
  }

  function updateConfig(partial) {
    var next = {}
    for (var k in config) next[k] = config[k]
    for (var p in partial) next[p] = partial[p]
    saveConfig(next)
  }

  function monitorMinimums() {
    if (!config.matchResolution) return { width: 0, height: 0 }
    try {
      var out = monitorsCollector.text || ""
      if (!out.trim()) return { width: 1920, height: 1080 }
      var monitors = JSON.parse(out)
      var w = 0
      var h = 0
      if (monitors && typeof monitors.length === "number") {
        for (var i = 0; i < monitors.length; i++) {
          var m = monitors[i]
          var mw = Number(m.width || 0)
          var mh = Number(m.height || 0)
          if (mw > w) w = mw
          if (mh > h) h = mh
        }
      }
      return { width: w, height: h }
    } catch (e) {
      return { width: 1920, height: 1080 }
    }
  }

  // afterRun: schedule a full interval from now (used after a completed fetch).
  // Otherwise honor lastSuccessAt + interval, or a short first-run delay.
  function scheduleNext(afterRun) {
    if (!enabled) {
      scheduleTimer.stop()
      writeStatus({ nextRunAt: "", busy: busy })
      return
    }
    var intervalMs = Math.max(1, Number(config.intervalHours) || 24) * 3600 * 1000
    var last = Date.parse(String(status.lastSuccessAt || ""))
    var nextMs
    if (afterRun === true) {
      nextMs = Date.now() + intervalMs
    } else if (isFinite(last) && last > 0) {
      nextMs = last + intervalMs
      if (nextMs <= Date.now() + 1000) nextMs = Date.now() + intervalMs
    } else {
      nextMs = Date.now() + 15000
    }
    var delay = Math.max(5000, nextMs - Date.now())
    // QML Timer interval is 32-bit; cap near 24 days.
    if (delay > 2147483647) delay = 2147483647
    scheduleTimer.interval = delay
    scheduleTimer.restart()
    writeStatus({ nextRunAt: new Date(Date.now() + delay).toISOString(), busy: busy })
  }

  function changeNow() {
    if (fetchProc.running || monitorsProc.running) {
      fetchQueued = true
      return
    }
    runFetch()
  }

  function runFetch() {
    if (sourceDir === "" || fetchScript === "/bin/fetch.sh") {
      writeStatus({
        busy: false,
        lastRunAt: new Date().toISOString(),
        lastError: "plugin source directory unavailable"
      })
      return
    }
    scheduleTimer.stop()
    ensureDirs()
    monitorsProc.running = true
  }

  function startFetchWithMonitors() {
    var mins = monitorMinimums()
    writeStatus({
      busy: true,
      lastRunAt: new Date().toISOString(),
      lastError: ""
    })
    fetchProc.command = [
      "bash", fetchScript,
      "--config", configPath,
      "--min-width", String(mins.width || 0),
      "--min-height", String(mins.height || 0)
    ]
    fetchProc.running = true
  }

  function handleFetchResult(raw, exitCode) {
    var result = { ok: false, source: "", path: "", error: "" }
    try {
      var parsed = JSON.parse(String(raw || "").trim().split("\n").pop() || "{}")
      if (parsed && typeof parsed === "object") result = parsed
    } catch (e) {
      result.error = "invalid fetch response"
    }
    if (exitCode !== 0 && !result.error)
      result.error = "fetch exited with code " + exitCode

    var patch = {
      busy: false,
      lastRunAt: new Date().toISOString(),
      lastError: result.ok ? "" : String(result.error || "fetch failed")
    }
    if (result.ok) {
      patch.lastSuccessAt = patch.lastRunAt
      patch.lastSource = String(result.source || "")
      patch.lastPath = String(result.path || "")
      if (config.notifyOnChange) {
        var label = patch.lastSource || "wallpaper"
        Quickshell.execDetached([
          "omarchy-notification-send",
          "Wallpaper updated",
          "Source: " + label
        ])
      }
    }
    writeStatus(patch)
    scheduleNext(true)
    Qt.callLater(refreshLog)
    if (fetchQueued) {
      fetchQueued = false
      Qt.callLater(runFetch)
    }
  }

  function openFolder() {
    var dir = Config.expandHome(config.wallpaperDir, home)
    Quickshell.execDetached(["xdg-open", dir])
  }

  function openLog() {
    ensureDirs()
    // xdg-open → nvim.desktop has no terminal from the shell process, so the
    // editor never appears. Use Omarchy's editor launcher (floating TUI).
    Quickshell.execDetached([
      "bash", "-lc",
      "touch -- \"$1\"; omarchy-launch-config-editor \"$1\"",
      "bash", logPath
    ])
  }

  function toggleEnabled() {
    updateConfig({ enabled: !enabled })
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    blockLoading: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.config = Config.parseConfigText(text(), root.home)
      root.configReady = true
      root.ensureDirs()
      root.scheduleNext()
    }
    onLoadFailed: {
      root.config = Config.mergeConfig({}, root.home)
      root.configReady = true
      root.ensureDirs()
      setText(Config.serializeConfig(root.config))
      root.scheduleNext()
    }
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    blockLoading: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      // Keep in-memory busy flag if a fetch is mid-flight.
      var loaded = Config.parseStatusText(text())
      if (root.busy) loaded.busy = true
      root.status = loaded
    }
    onLoadFailed: root.status = Config.parseStatusText("")
  }

  FileView {
    id: logFile
    path: root.logPath
    watchChanges: true
    blockLoading: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyLogText(text())
    onLoadFailed: root.recentAttempts = []
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      id: monitorsCollector
      waitForEnd: true
    }
    onExited: function() {
      root.startFetchWithMonitors()
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      id: fetchOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: fetchErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var raw = fetchOut.text || ""
      if (!String(raw).trim() && fetchErr.text)
        raw = JSON.stringify({ ok: false, error: String(fetchErr.text).trim().split("\n").pop() })
      root.handleFetchResult(raw, exitCode)
    }
  }

  Timer {
    id: scheduleTimer
    repeat: false
    onTriggered: {
      if (root.enabled) root.runFetch()
    }
  }

  // Re-check schedule hourly in case the machine slept through the timer.
  Timer {
    interval: 3600000
    running: true
    repeat: true
    onTriggered: {
      if (!root.enabled || root.busy) return
      var next = Date.parse(String(root.nextRunAt || ""))
      if (!isFinite(next) || next <= Date.now()) root.scheduleNext()
    }
  }

  ShellIpc {
    target: "rodrigoboni.daily-wallpaper"

    function change(): string {
      root.changeNow()
      return "ok"
    }

    function refresh(): string {
      root.changeNow()
      return "ok"
    }

    function toggle(): string {
      root.toggleEnabled()
      return root.enabled ? "enabled" : "disabled"
    }

    function status(): string {
      var cfg = {}
      for (var k in root.config) cfg[k] = root.config[k]
      // Never echo secrets over IPC / notifications.
      if (cfg.nasaApiKey) cfg.nasaApiKey = cfg.nasaApiKey.length > 0 ? "(set)" : ""
      if (cfg.unsplashAccessKey) cfg.unsplashAccessKey = cfg.unsplashAccessKey.length > 0 ? "(set)" : ""
      return JSON.stringify({
        enabled: root.enabled,
        busy: root.busy,
        lastSource: root.lastSource,
        lastPath: root.lastPath,
        lastError: root.lastError,
        lastSuccessAt: root.lastSuccessAt,
        nextRunAt: root.nextRunAt,
        config: cfg
      })
    }

    function openFolder(): string {
      root.openFolder()
      return "ok"
    }

    function openLog(): string {
      root.openLog()
      return "ok"
    }
  }

  Component.onCompleted: {
    ensureDirs()
    if (!configReady) configFile.reload()
    statusFile.reload()
    logFile.reload()
  }
}
