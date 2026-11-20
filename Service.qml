import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
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
  property bool forceFetch: false
  property bool deferredDue: false
  property bool sleeping: false
  property bool displayAwake: true
  property int prevKeepDays: -1

  readonly property bool enabled: config.enabled === true
  readonly property bool busy: status.busy === true || fetchProc.running || monitorsProc.running || gateMonitorsProc.running
  readonly property string lastSource: String(status.lastSource || "")
  readonly property string lastPath: String(status.lastPath || "")
  readonly property string lastError: String(status.lastError || "")
  readonly property string lastSuccessAt: String(status.lastSuccessAt || "")
  readonly property string lastRunAt: String(status.lastRunAt || "")
  readonly property string nextRunAt: String(status.nextRunAt || "")
  readonly property string skipReason: String(status.skipReason || "")
  readonly property string lastResult: String(status.lastResult || "")
  readonly property int retryCount: Number(status.retryCount || 0)
  readonly property bool onBattery: UPower.onBattery === true
  readonly property bool pauseOnBattery: config.pauseOnBattery === true

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
    hardenConfigPerms()
  }

  // Config may hold API keys — directory 700, file 600.
  function hardenConfigPerms() {
    Quickshell.execDetached([
      "bash", "-lc",
      "umask 077\n" +
      "dir=$1; file=$2\n" +
      "mkdir -p -- \"$dir\" && chmod 700 -- \"$dir\" || exit 0\n" +
      "if [[ -f $file ]]; then chmod 600 -- \"$file\"; fi\n",
      "daily-wallpaper-perms",
      home + "/.config/omarchy/daily-wallpaper",
      configPath
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
    var prevKeep = Number(config.keepDays || 7)
    config = Config.mergeConfig(nextCfg, home)
    configFile.setText(Config.serializeConfig(config))
    hardenConfigPerms()
    if (Number(config.keepDays) !== prevKeep)
      Qt.callLater(runPurgeOnly)
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

  function parseDisplayAwake(raw) {
    try {
      var monitors = JSON.parse(String(raw || "").trim() || "[]")
      if (!monitors || typeof monitors.length !== "number" || monitors.length === 0)
        return true
      for (var i = 0; i < monitors.length; i++) {
        var m = monitors[i]
        if (m && m.disabled !== true && m.dpmsStatus !== false)
          return true
      }
      return false
    } catch (e) {
      return true
    }
  }

  function scheduledBlockedReason() {
    if (sleeping) return "sleeping"
    if (!displayAwake) return "display_off"
    if (pauseOnBattery && onBattery) return "battery"
    return ""
  }

  function deferScheduled(reason) {
    deferredDue = true
    writeStatus({
      skipReason: reason,
      busy: false,
      lastResult: "skipped"
    })
    if (!deferPollTimer.running) {
      deferPollTimer.interval = 60000
      deferPollTimer.restart()
    }
  }

  function clearDeferral() {
    deferredDue = false
    if (status.skipReason)
      writeStatus({ skipReason: "" })
  }

  // afterRun: schedule a full interval from now (used after a completed fetch).
  // retryBackoff: use bounded retry delays instead of intervalHours.
  function scheduleNext(afterRun, retryBackoff) {
    if (!enabled) {
      scheduleTimer.stop()
      writeStatus({ nextRunAt: "", busy: busy, skipReason: "" })
      return
    }
    var delay
    if (retryBackoff === true) {
      var count = Math.max(1, Number(status.retryCount || 1))
      delay = Config.retryBackoffMs(count)
    } else {
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
      delay = Math.max(5000, nextMs - Date.now())
    }
    // QML Timer interval is 32-bit; cap near 24 days.
    if (delay > 2147483647) delay = 2147483647
    scheduleTimer.interval = delay
    scheduleTimer.restart()
    writeStatus({ nextRunAt: new Date(Date.now() + delay).toISOString(), busy: busy })
  }

  function changeNow() {
    forceFetch = true
    clearDeferral()
    // If a fetch is already downloading, queue a follow-up forced run.
    // If only preflight (DPMS/monitors) is running, upgrade that run to forced
    // instead of scheduling a duplicate.
    if (fetchProc.running) {
      fetchQueued = true
      return
    }
    if (monitorsProc.running || gateMonitorsProc.running)
      return
    runFetch(true)
  }

  function runFetch(force) {
    forceFetch = force === true
    if (sourceDir === "" || fetchScript === "/bin/fetch.sh") {
      writeStatus({
        busy: false,
        lastRunAt: new Date().toISOString(),
        lastError: "plugin source directory unavailable",
        lastResult: "failure"
      })
      return
    }
    if (!forceFetch) {
      var blocked = scheduledBlockedReason()
      if (blocked) {
        deferScheduled(blocked)
        return
      }
      // Re-check DPMS right before starting (may have changed since last poll).
      if (!gateMonitorsProc.running && !monitorsProc.running && !fetchProc.running) {
        gateMonitorsProc.running = true
        return
      }
    }
    scheduleTimer.stop()
    ensureDirs()
    monitorsProc.running = true
  }

  function continueAfterGateCheck() {
    if (!forceFetch) {
      var blocked = scheduledBlockedReason()
      if (blocked) {
        deferScheduled(blocked)
        return
      }
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
      lastError: "",
      skipReason: "",
      lastResult: "running"
    })
    clearDeferral()
    fetchProc.command = [
      "bash", fetchScript,
      "--config", configPath,
      "--min-width", String(mins.width || 0),
      "--min-height", String(mins.height || 0),
      "--protect", String(status.lastPath || "")
    ]
    fetchProc.running = true
  }

  function runPurgeOnly() {
    if (sourceDir === "" || fetchScript === "/bin/fetch.sh") return
    if (purgeProc.running) return
    ensureDirs()
    purgeProc.command = [
      "bash", fetchScript,
      "--config", configPath,
      "--purge-only",
      "--protect", String(status.lastPath || "")
    ]
    purgeProc.running = true
  }

  function handleFetchResult(raw, exitCode) {
    var wasForced = forceFetch
    forceFetch = false
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
      lastError: result.ok ? "" : String(result.error || "fetch failed"),
      skipReason: ""
    }

    if (result.ok) {
      patch.lastSuccessAt = patch.lastRunAt
      patch.lastSource = String(result.source || "")
      patch.lastPath = String(result.path || "")
      patch.lastResult = "success"
      patch.retryCount = 0
      if (config.notifyOnChange) {
        var label = patch.lastSource || "wallpaper"
        Quickshell.execDetached([
          "omarchy-notification-send",
          "Wallpaper updated",
          "Source: " + label
        ])
      }
      writeStatus(patch)
      scheduleNext(true, false)
    } else {
      patch.lastResult = "failure"
      var err = String(result.error || "")
      var allFailed = err.indexOf("all sources failed") >= 0
          || err.indexOf("no eligible sources") >= 0
      var nextRetry = allFailed ? Number(status.retryCount || 0) + 1 : 0
      if (allFailed && nextRetry <= Config.RETRY_MAX) {
        patch.retryCount = nextRetry
        writeStatus(patch)
        scheduleNext(true, true)
      } else {
        patch.retryCount = 0
        writeStatus(patch)
        scheduleNext(true, false)
      }
    }

    Qt.callLater(refreshLog)
    if (fetchQueued) {
      fetchQueued = false
      Qt.callLater(function() { root.runFetch(true) })
    } else if (wasForced) {
      // forced run finished; nothing else
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

  function tryFlushDeferred() {
    if (!enabled || busy || sleeping) return
    var blocked = scheduledBlockedReason()
    if (blocked) {
      deferScheduled(blocked)
      return
    }
    if (deferredDue) {
      clearDeferral()
      runFetch(false)
      return
    }
    var next = Date.parse(String(nextRunAt || ""))
    if (!isFinite(next) || next <= Date.now())
      scheduleNext()
  }

  function requestGateRecheck() {
    if (!gateCheckPollProc.running)
      gateCheckPollProc.running = true
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
      if (root.prevKeepDays >= 0 && root.prevKeepDays !== Number(root.config.keepDays))
        Qt.callLater(root.runPurgeOnly)
      root.prevKeepDays = Number(root.config.keepDays)
      root.scheduleNext()
    }
    onLoadFailed: {
      root.config = Config.mergeConfig({}, root.home)
      root.configReady = true
      root.ensureDirs()
      setText(Config.serializeConfig(root.config))
      root.hardenConfigPerms()
      root.prevKeepDays = Number(root.config.keepDays)
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

  // Pre-flight DPMS check for scheduled runs.
  Process {
    id: gateMonitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      id: gateMonitorsCollector
      waitForEnd: true
    }
    onExited: function() {
      root.displayAwake = root.parseDisplayAwake(gateMonitorsCollector.text || "")
      root.continueAfterGateCheck()
    }
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      id: monitorsCollector
      waitForEnd: true
    }
    onExited: function() {
      root.displayAwake = root.parseDisplayAwake(monitorsCollector.text || "")
      if (!root.forceFetch) {
        var blocked = root.scheduledBlockedReason()
        if (blocked) {
          root.deferScheduled(blocked)
          return
        }
      }
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

  Process {
    id: purgeProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Watch logind PrepareForSleep so we defer across suspend/resume.
  Process {
    id: sleepMonitorProc
    running: true
    command: [
      "gdbus", "monitor", "--system",
      "--dest", "org.freedesktop.login1",
      "--object-path", "/org/freedesktop/login1"
    ]
    stdout: SplitParser {
      onRead: function(line) {
        var s = String(line || "")
        if (s.indexOf("PrepareForSleep") < 0) return
        if (s.indexOf("true") >= 0) {
          root.sleeping = true
          if (root.status.skipReason !== "sleeping")
            root.writeStatus({ skipReason: "sleeping" })
        } else if (s.indexOf("false") >= 0) {
          root.sleeping = false
          Qt.callLater(root.requestGateRecheck)
        }
      }
    }
    onExited: function() {
      // Keep the watch alive across gdbus/logind blips.
      sleepMonitorRestart.restart()
    }
  }

  Timer {
    id: sleepMonitorRestart
    interval: 2000
    repeat: false
    onTriggered: {
      if (!sleepMonitorProc.running)
        sleepMonitorProc.running = true
    }
  }

  Timer {
    id: scheduleTimer
    repeat: false
    onTriggered: {
      if (root.enabled) root.runFetch(false)
    }
  }

  Timer {
    id: deferPollTimer
    repeat: true
    interval: 60000
    onTriggered: {
      if (!root.enabled || root.busy) return
      if (!root.deferredDue && !root.sleeping && !(root.pauseOnBattery && root.onBattery)) {
        stop()
        return
      }
      // Refresh DPMS, then try flush.
      if (!gateCheckPollProc.running)
        gateCheckPollProc.running = true
    }
  }

  Process {
    id: gateCheckPollProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      id: gateCheckPollCollector
      waitForEnd: true
    }
    onExited: function() {
      root.displayAwake = root.parseDisplayAwake(gateCheckPollCollector.text || "")
      root.tryFlushDeferred()
    }
  }

  // Re-check schedule hourly in case the machine slept through the timer.
  Timer {
    interval: 3600000
    running: true
    repeat: true
    onTriggered: {
      if (!root.enabled || root.busy) return
      if (root.deferredDue) {
        root.tryFlushDeferred()
        return
      }
      var next = Date.parse(String(root.nextRunAt || ""))
      if (!isFinite(next) || next <= Date.now()) root.scheduleNext()
    }
  }

  // Daily retention sweep even if fetches keep failing.
  Timer {
    interval: 86400000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runPurgeOnly()
  }

  onOnBatteryChanged: {
    if (!root.enabled || root.busy) return
    if (root.pauseOnBattery && root.onBattery) {
      if (!root.forceFetch)
        root.deferScheduled("battery")
    } else if (root.deferredDue) {
      Qt.callLater(root.requestGateRecheck)
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
        lastRunAt: root.lastRunAt,
        nextRunAt: root.nextRunAt,
        skipReason: root.skipReason,
        lastResult: root.lastResult,
        retryCount: root.retryCount,
        onBattery: root.onBattery,
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

    function purge(): string {
      root.runPurgeOnly()
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
