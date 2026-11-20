import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Config.js" as Config

Panel {
  id: root
  moduleName: "rodrigoboni.daily-wallpaper"
  ipcTarget: "rodrigoboni.daily-wallpaper.panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property bool openedFromHotkey: false
  property bool cursorActive: false
  property int focusIndex: 0

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property var cfg: service ? service.config : Config.mergeConfig({}, Quickshell.env("HOME"))
  readonly property bool busy: service ? service.busy : false
  readonly property bool rotationEnabled: service ? service.enabled : true
  readonly property string lastSource: service ? String(service.lastSource || "") : ""
  readonly property string lastError: service ? String(service.lastError || "") : ""
  readonly property string lastSuccessAt: service ? String(service.lastSuccessAt || "") : ""
  readonly property string lastRunAt: service ? String(service.lastRunAt || "") : ""
  readonly property string nextRunAt: service ? String(service.nextRunAt || "") : ""
  readonly property string skipReason: service ? String(service.skipReason || "") : ""
  readonly property string lastResult: service ? String(service.lastResult || "") : ""
  readonly property int retryCount: service ? Number(service.retryCount || 0) : 0
  readonly property string logPath: Quickshell.env("HOME") + "/.local/state/omarchy/daily-wallpaper/fetch.log"

  readonly property var sourceOptions: [
    { value: "bing", label: strings.t("source.bing") },
    { value: "apod", label: strings.t("source.apod") },
    { value: "met", label: strings.t("source.met") },
    { value: "nasa_images", label: strings.t("source.nasa_images") },
    { value: "unsplash", label: strings.t("source.unsplash") }
  ]

  readonly property string heroMeta: {
    if (busy) return strings.t("busy")
    if (!rotationEnabled) return strings.t("disabled")
    if (skipReason !== "") return skipReasonLabel(skipReason)
    if (lastSource !== "") return strings.t("lastSource").arg(sourceLabel(lastSource))
    if (lastError !== "") return strings.t("error").arg(lastError)
    return strings.t("neverRun")
  }

  readonly property string nextLabel: {
    if (!rotationEnabled || nextRunAt === "") return ""
    var ms = Date.parse(nextRunAt) - Date.now()
    if (!isFinite(ms) || ms < 0) return strings.t("idle")
    var minutes = Math.round(ms / 60000)
    if (minutes < 60) return strings.t("nextIn").arg(strings.tn("minutes", Math.max(1, minutes)).arg(Commons.I18n.formatNumber(Math.max(1, minutes))))
    var hours = Math.max(1, Math.round(minutes / 60))
    return strings.t("nextIn").arg(strings.tn("hours", hours).arg(Commons.I18n.formatNumber(hours)))
  }

  readonly property string statusResultLine: {
    if (busy) return strings.t("statusRunning")
    if (lastResult === "success") return strings.t("statusSuccess")
    if (lastResult === "failure") return strings.t("statusFailure")
    if (lastResult === "skipped") return strings.t("statusSkipped")
    if (lastSuccessAt !== "") return strings.t("statusSuccess")
    if (lastError !== "") return strings.t("statusFailure")
    return strings.t("statusUnknown")
  }

  readonly property string statusSourceLine: {
    if (lastSource === "") return strings.t("statusNoSource")
    return strings.t("statusSource").arg(sourceLabel(lastSource))
  }

  readonly property string statusWhenLine: {
    var iso = lastSuccessAt || lastRunAt
    var local = Config.formatLocalDateTime(iso)
    if (local === "") return strings.t("statusNeverChanged")
    if (lastSuccessAt !== "") return strings.t("statusChangedAt").arg(local)
    return strings.t("statusRanAt").arg(local)
  }

  readonly property string statusExtraLine: {
    if (retryCount > 0)
      return strings.t("statusRetry").arg(Commons.I18n.formatNumber(retryCount)).arg(Commons.I18n.formatNumber(Config.RETRY_MAX))
    if (skipReason !== "") return skipReasonLabel(skipReason)
    if (lastResult === "failure" && lastError !== "") return strings.t("error").arg(lastError)
    return ""
  }

  function sourceLabel(id) {
    var key = "source." + id
    var label = strings.t(key)
    return label === key ? id : label
  }

  function skipReasonLabel(reason) {
    if (reason === "display_off") return strings.t("skipDisplayOff")
    if (reason === "sleeping") return strings.t("skipSleeping")
    if (reason === "battery") return strings.t("skipBattery")
    return strings.t("skipOther").arg(reason || "?")
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function patchConfig(partial) {
    if (service && service.updateConfig) service.updateConfig(partial)
  }

  function changeNow() {
    if (service && service.changeNow) service.changeNow()
  }

  function openFolder() {
    if (service && service.openFolder) service.openFolder()
  }

  function openLog() {
    if (service && service.openLog) {
      service.openLog()
      return
    }
    Quickshell.execDetached([
      "bash", "-lc",
      "mkdir -p \"$(dirname \"$1\")\"; touch -- \"$1\"; omarchy-launch-config-editor \"$1\"",
      "bash", root.logPath
    ])
  }

  function toggleEnabled() {
    if (service && service.toggleEnabled) service.toggleEnabled()
  }

  readonly property int controlCount: 16

  function moveFocus(dy) {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    focusIndex = Math.max(0, Math.min(controlCount - 1, focusIndex + dy))
    scrollFocusIntoView()
  }

  function activateFocus() {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    if (focusIndex === 0) changeNow()
    else if (focusIndex === 1) openFolder()
    else if (focusIndex === 2) openLog()
    else if (focusIndex === 3) toggleEnabled()
  }

  function scrollFocusIntoView() {
    var flick = panel.loadedContent ? panel.loadedContent.panelFlick : null
    if (!flick) return
    var item = null
    if (focusIndex === 0) item = panel.loadedContent.changeBtn
    else if (focusIndex === 1) item = panel.loadedContent.folderBtn
    else if (focusIndex === 2) item = panel.loadedContent.logBtn
    else if (focusIndex === 3) item = panel.loadedContent.enabledToggle
    if (!item) return
    var y = item.mapToItem(flick.contentItem, 0, 0).y
    var bottom = y + item.height
    if (y < flick.contentY) flick.contentY = Math.max(0, y - Style.space(12))
    else if (bottom > flick.contentY + flick.height)
      flick.contentY = Math.min(flick.contentHeight - flick.height, bottom - flick.height + Style.space(12))
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusIndex = 0
    if (service && service.refreshLog) service.refreshLog()
    if (panel.loadedContent && panel.loadedContent.panelFlick)
      panel.loadedContent.panelFlick.contentY = 0
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias changeBtn: changeBtn
      property alias folderBtn: folderBtn
      property alias logBtn: logBtn
      property alias enabledToggle: enabledToggle

      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveFocus(dy)
      }
      onActivateRequested: root.activateFocus()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.changeNow()
        else if (t === "o" || t === "O") root.openFolder()
        else if (t === "l" || t === "L") root.openLog()
        else if (t === " ") root.toggleEnabled()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: root.heroMeta
            detail: root.nextLabel
            foreground: root.foreground
          }

          Column {
            id: actionColumn
            width: parent.width
            spacing: Style.space(8)

            Row {
              id: actionRow
              width: parent.width
              spacing: Style.space(8)

              Button {
                id: changeBtn
                text: strings.t("changeNow")
                foreground: root.foreground
                enabled: !root.busy
                hasCursor: root.cursorActive && root.focusIndex === 0
                onClicked: root.changeNow()
                onHovered: function(on) {
                  if (on) { root.cursorActive = true; root.focusIndex = 0 }
                }
              }

              Button {
                id: folderBtn
                text: strings.t("openFolder")
                foreground: root.foreground
                bordered: true
                hasCursor: root.cursorActive && root.focusIndex === 1
                onClicked: root.openFolder()
                onHovered: function(on) {
                  if (on) { root.cursorActive = true; root.focusIndex = 1 }
                }
              }
            }

            Button {
              id: logBtn
              width: parent.width
              text: strings.t("openLog")
              foreground: root.foreground
              bordered: true
              hasCursor: root.cursorActive && root.focusIndex === 2
              onClicked: root.openLog()
              onHovered: function(on) {
                if (on) { root.cursorActive = true; root.focusIndex = 2 }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              text: strings.t("statusSection")
              foreground: root.foreground
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.statusResultLine
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.statusSourceLine
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.statusWhenLine
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.nextLabel !== ""
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.nextLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.statusExtraLine !== ""
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.statusExtraLine
              color: Qt.darker(root.foreground, 1.1)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width }

          Toggle {
            id: enabledToggle
            width: parent.width
            label: strings.t("enabled")
            description: strings.t("enabledHint")
            checked: root.rotationEnabled
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 3
            onClicked: root.toggleEnabled()
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 3 }
            }
          }

          NumberField {
            width: parent.width
            label: strings.t("intervalHours")
            value: Number(root.cfg.intervalHours || 24)
            from: 1
            to: 168
            stepSize: 1
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 4
            onModified: function(v) { root.patchConfig({ intervalHours: v }) }
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 4 }
            }
          }

          NumberField {
            width: parent.width
            label: strings.t("keepDays")
            value: Number(root.cfg.keepDays || 7)
            from: 1
            to: 365
            stepSize: 1
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 5
            onModified: function(v) { root.patchConfig({ keepDays: v }) }
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 5 }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("wallpaperDir")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: String(root.cfg.wallpaperDir || "")
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusIndex === 6
              onEditingFinished: root.patchConfig({ wallpaperDir: text.trim() })
              onHoveredChanged: {
                if (hovered) { root.cursorActive = true; root.focusIndex = 6 }
              }
            }
          }

          MultiSelect {
            width: parent.width
            label: strings.t("sources")
            options: root.sourceOptions
            values: root.cfg.sources || []
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 7
            onChanged: function(values) { root.patchConfig({ sources: values }) }
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 7 }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("keywords")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: strings.t("keywordsHint")
              color: Qt.darker(root.dim, 1.1)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            TextField {
              width: parent.width
              text: String(root.cfg.keywords || "")
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusIndex === 8
              onEditingFinished: root.patchConfig({ keywords: text.trim() })
              onHoveredChanged: {
                if (hovered) { root.cursorActive = true; root.focusIndex = 8 }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("metQuery")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: String(root.cfg.metQuery || "")
              placeholderText: String(root.cfg.keywords || "").split(",")[0] || "landscape"
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusIndex === 9
              onEditingFinished: root.patchConfig({ metQuery: text.trim() })
              onHoveredChanged: {
                if (hovered) { root.cursorActive = true; root.focusIndex = 9 }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("unsplashQuery")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: String(root.cfg.unsplashQuery || "")
              placeholderText: String(root.cfg.keywords || "").split(",")[0] || "landscape"
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusIndex === 10
              onEditingFinished: root.patchConfig({ unsplashQuery: text.trim() })
              onHoveredChanged: {
                if (hovered) { root.cursorActive = true; root.focusIndex = 10 }
              }
            }
          }

          Toggle {
            width: parent.width
            label: strings.t("matchResolution")
            description: strings.t("matchResolutionHint")
            checked: root.cfg.matchResolution !== false
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 11
            onClicked: root.patchConfig({ matchResolution: !(root.cfg.matchResolution !== false) })
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 11 }
            }
          }

          Toggle {
            width: parent.width
            label: strings.t("applyToLock")
            description: strings.t("applyToLockHint")
            checked: root.cfg.applyToLockScreen !== false
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 12
            onClicked: root.patchConfig({ applyToLockScreen: !(root.cfg.applyToLockScreen !== false) })
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 12 }
            }
          }

          Toggle {
            width: parent.width
            label: strings.t("notifyOnChange")
            checked: root.cfg.notifyOnChange !== false
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 13
            onClicked: root.patchConfig({ notifyOnChange: !(root.cfg.notifyOnChange !== false) })
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 13 }
            }
          }

          Toggle {
            width: parent.width
            label: strings.t("pauseOnBattery")
            description: strings.t("pauseOnBatteryHint")
            checked: root.cfg.pauseOnBattery === true
            foreground: root.foreground
            hasCursor: root.cursorActive && root.focusIndex === 14
            onClicked: root.patchConfig({ pauseOnBattery: !(root.cfg.pauseOnBattery === true) })
            onHovered: function(on) {
              if (on) { root.cursorActive = true; root.focusIndex = 14 }
            }
          }

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: strings.t("keysHint")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("nasaApiKey")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: String(root.cfg.nasaApiKey || "")
              password: true
              foreground: root.foreground
              hasCursor: root.cursorActive && root.focusIndex === 15
              onEditingFinished: root.patchConfig({ nasaApiKey: text.trim() })
              onHoveredChanged: {
                if (hovered) { root.cursorActive = true; root.focusIndex = 15 }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("unsplashAccessKey")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: String(root.cfg.unsplashAccessKey || "")
              password: true
              foreground: root.foreground
              onEditingFinished: root.patchConfig({ unsplashAccessKey: text.trim() })
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: strings.t("bingMkt")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: String(root.cfg.bingMkt || "en-US")
              foreground: root.foreground
              onEditingFinished: root.patchConfig({ bingMkt: text.trim() || "en-US" })
            }
          }
        }
      }
    }
  }
}
