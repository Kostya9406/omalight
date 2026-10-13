import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Search.js" as Search
import "Strings.js" as Strings

// The OmaLight mark on the bar. Click opens the bar; the tooltip carries
// Claude's limits from the record Omarchy's agent-usage collector keeps.
BarWidget {
  id: root
  moduleName: "io.github.kostya9406.omalight"

  property var limits: null
  // The language the bar itself uses: settings.json when it names one, else the system locale.
  property string lang: ""
  readonly property bool ru: root.lang ? root.lang === "ru" : Strings.isRussian(Qt.locale().name)
  readonly property bool showLimit: root.setting("showLimit", false) && !!(root.limits && root.limits.session)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The mark is drawn over the button; the label only carries the optional percentage.
    text: root.showLimit ? "   " + root.limits.session.percent + "%" : "   "
    horizontalMargin: 7.5
    tooltipText: {
      var tip = Strings.tr("widgetTip", root.ru)
      var l = root.limits
      if (l && l.session && l.week)
        tip += "\n" + Strings.tr("limitsTip", root.ru).replace("%1", l.session.percent).replace("%2", l.week.percent)
      return tip
    }
    onPressed: function(b) {
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.moduleName, "{}"])
    }

    YinYang {
      anchors.left: parent.left
      anchors.leftMargin: Style.spaceReal(button.horizontalMargin)
      anchors.verticalCenter: parent.verticalCenter
      width: 16
      height: 16
      color: button.foreground
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omalight/settings.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        root.lang = s.lang === "ru" || s.lang === "en" ? s.lang : ""
      } catch (e) {
        root.lang = ""
      }
    }
    onFileChanged: reload()
    onLoadFailed: root.lang = ""
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/agents/usage/claude.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.limits = Search.claudeUsage(text())
    onFileChanged: reload()
  }
}
