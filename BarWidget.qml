import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Pin icon with the number of windows waiting in the scratchpad.
// Left click shows/hides the scratchpad, right click opens the pinned-app list.
BarWidget {
  id: root
  moduleName: "io.github.yoann54.scratchpad-pinned"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // The service is mounted by the shell; it can appear a little after us.
  property var service: null
  property int serviceAttempts: 0
  function findService() {
    var shell = root.bar ? root.bar.shell : null
    root.service = shell && typeof shell.serviceFor === "function" ? shell.serviceFor(root.moduleName) : null
  }
  Timer {
    interval: 300
    repeat: true
    running: !root.service && root.serviceAttempts < 20
    onTriggered: { root.findService(); root.serviceAttempts += 1 }
  }
  Component.onCompleted: findService()

  readonly property int count: service ? service.count : 0
  readonly property var windows: service ? service.scratchpadWindows : []
  // How many hidden windows each app has: the window title is only shown when
  // it is needed to tell two windows of the same app apart.
  readonly property var windowsPerApp: {
    var n = {}
    for (var i = 0; i < windows.length; i++) {
      var k = String(windows[i].appId).toLowerCase()
      n[k] = (n[k] || 0) + 1
    }
    return n
  }
  readonly property var apps: service ? service.apps : []
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", false) === true

  property bool popupOpen: false
  // Host contract: `omarchy-shell shell toggle <id>` (and summon/hide) open
  // this widget's popup on the focused monitor through these.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  // No number in the bar: the glyph says whether anything is hidden (filled
  // pin) or not (outlined, dimmed). The count is in the tooltip and popup.
  visible: !!service && !(hideWhenEmpty && count === 0 && !popupOpen)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  function handlePress(b) {
    if (!root.service) return
    if (b === Qt.RightButton) root.popupOpen = !root.popupOpen
    else if (b === Qt.MiddleButton) root.service.pinActive("startup")
    else root.service.toggleScratchpad()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.count > 0 ? "󰐃" : "󰤱"
    dimmed: root.count === 0
    useActiveColor: false
    tooltipText: strings.tn("tooltip.count", root.count).arg(Commons.I18n.formatNumber(root.count))
    onPressed: function(b) { root.handlePress(b) }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  // A KeyboardPanel rather than a PopupCard: the app picker needs typing.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: popup.loadedContent
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(popup.loadedContentHeight, Style.space(640))

    // Built on first open, not at startup on every monitor.
    content: FocusScope {
      id: keys
      implicitHeight: column.implicitHeight
      Keys.onEscapePressed: root.close()

    Column {
      id: column
      width: parent.width
      spacing: Style.space(8)

      PanelSectionHeader {
        width: parent.width
        text: strings.t("popup.pinned")
      }

      PlainText {
        width: parent.width
        opacity: 0.7
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        font.pixelSize: Style.font.caption
        text: root.apps.length === 0 ? strings.t("popup.noPinned") : strings.t("popup.pinnedHint")
      }

      Repeater {
        model: root.apps
        delegate: Row {
          required property var modelData
          width: column.width
          spacing: Style.space(6)

          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - modeButton.width - launchButton.width - removeButton.width - parent.spacing * 3
            text: modelData.name
          }
          Button {
            id: modeButton
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            text: modelData.mode === "always" ? strings.t("mode.always") : strings.t("mode.startup")
            tooltipText: modelData.mode === "always" ? strings.t("mode.alwaysHint") : strings.t("mode.startupHint")
            onClicked: root.service.setMode(modelData.appId, modelData.mode === "always" ? "startup" : "always")
          }
          Button {
            id: launchButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐊"
            tooltipText: strings.t("popup.launch")
            onClicked: root.service.launchNow(modelData.appId)
          }
          Button {
            id: removeButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅖"
            tooltipText: strings.t("popup.unpin")
            onClicked: root.service.unpin(modelData.appId)
          }
        }
      }

      SearchableDropdown {
        id: picker
        width: parent.width
        showLabel: false
        value: ""
        triggerLabel: ""
        placeholderText: strings.t("popup.addApp")
        emptyText: strings.t("popup.noMatch")
        options: (root.service ? root.service.pinnableEntries : []).map(function(e) {
          return {
            value: e.id,
            label: e.name,
            description: e.running ? strings.t("popup.appOpen") : e.genericName
          }
        })
        onChanged: function(v) {
          if (v && root.service) root.service.pinEntry(v, "startup")
          picker.value = ""
        }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader {
        width: parent.width
        text: strings.tn("tooltip.count", root.count).arg(Commons.I18n.formatNumber(root.count))
      }

      PlainText {
        width: parent.width
        visible: root.count === 0
        opacity: 0.7
        font.pixelSize: Style.font.caption
        text: strings.t("popup.emptyScratchpad")
      }

      Repeater {
        model: root.windows
        delegate: Row {
          required property var modelData
          width: column.width
          spacing: Style.space(6)

          Button {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - bringButton.width - pinButton.width - parent.spacing * 2
            leftAlign: true
            readonly property bool needsTitle: (root.windowsPerApp[String(modelData.appId).toLowerCase()] || 0) > 1
              && modelData.title !== "" && modelData.title !== modelData.name
            text: needsTitle
              ? strings.t("popup.windowLabel").arg(modelData.name).arg(modelData.title)
              : modelData.name
            tooltipText: modelData.title !== "" && modelData.title !== modelData.name
              ? strings.t("popup.showWindowTitled").arg(modelData.title)
              : strings.t("popup.showWindow")
            onClicked: { root.close(); root.service.focusWindow(modelData.address) }
          }
          Button {
            id: bringButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰁅"
            tooltipText: strings.t("popup.bringWindow")
            onClicked: { root.close(); root.service.bringWindow(modelData.address) }
          }
          Button {
            id: pinButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐃"
            selected: modelData.pinned
            active: modelData.pinned
            tooltipText: modelData.pinned
              ? strings.t("popup.unpinApp").arg(modelData.name)
              : strings.t("popup.pinApp").arg(modelData.name)
            onClicked: root.service.togglePinWindow(modelData.address)
          }
        }
      }
    }
    }
  }
}
