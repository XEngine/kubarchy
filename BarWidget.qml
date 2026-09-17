import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for Kubarchy. Owns nothing about clusters itself — it just hosts
// the popup panel and forwards the bar/settings context into it, same
// shape every other icon-plus-popup widget (clock, weather) uses.
BarWidget {
  id: root
  moduleName: "xengine.kubarchy"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
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
    tooltipText: "Kubarchy"

    // Drawn rather than a font glyph: the obvious Unicode helm-wheel
    // symbol (U+2388) isn't in the Nerd Font icon ranges this shell's
    // fonts actually cover, so it renders as a blank/tofu box instead of
    // an icon. A small hand-drawn wheel sidesteps font coverage entirely.
    iconComponent: Component {
      Canvas {
        id: wheelCanvas
        property color strokeColor: button.foreground
        onStrokeColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var cx = width / 2
          var cy = height / 2
          var r = Math.min(width, height) / 2 - 1
          ctx.strokeStyle = strokeColor
          ctx.fillStyle = strokeColor
          ctx.lineWidth = Math.max(1, r * 0.16)

          ctx.beginPath()
          ctx.arc(cx, cy, r, 0, Math.PI * 2)
          ctx.stroke()

          ctx.beginPath()
          ctx.arc(cx, cy, r * 0.22, 0, Math.PI * 2)
          ctx.fill()

          for (var i = 0; i < 6; i++) {
            var a = (Math.PI * 2 / 6) * i - Math.PI / 2
            ctx.beginPath()
            ctx.moveTo(cx + Math.cos(a) * r * 0.4, cy + Math.sin(a) * r * 0.4)
            ctx.lineTo(cx + Math.cos(a) * r * 0.95, cy + Math.sin(a) * r * 0.95)
            ctx.stroke()
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh() }
      else root.togglePanel()
    }
  }
}
