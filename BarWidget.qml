import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "rodrigoboni.daily-wallpaper"

  readonly property var wallpaperService: {
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return null
    return bar.shell.serviceFor("rodrigoboni.daily-wallpaper")
  }

  readonly property bool showLabel: setting("showLabel", false) === true
  readonly property string sourceLabel: {
    if (!wallpaperService) return ""
    return String(wallpaperService.lastSource || "")
  }
  readonly property string buttonText: {
    if (wallpaperService && wallpaperService.busy) return "󰋱"
    if (showLabel && sourceLabel !== "") return "󰋩 " + sourceLabel
    return "󰋩"
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.wallpaperService
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    else if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onWallpaperServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.buttonText
    slotSize: Style.bar.statusSlot
    tooltipText: ""
    opacity: root.wallpaperService && root.wallpaperService.enabled === false ? 0.55 : 1

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        if (root.wallpaperService && root.wallpaperService.changeNow)
          root.wallpaperService.changeNow()
      } else if (b === Qt.MiddleButton) {
        if (root.wallpaperService && root.wallpaperService.openFolder)
          root.wallpaperService.openFolder()
      } else {
        root.togglePanel()
      }
    }
  }
}
