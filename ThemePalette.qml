import QtQuick
import Quickshell.Io
import qs.Commons

// The current theme's colors, read from its colors.toml, so the accent picker
// can draw each choice in its real color. The names are the ones the service
// accepts for --set-accent (the list in lib/hyprchroma-palette).
Item {
  id: root

  property var colors: ({})
  readonly property var names: ["blue", "cyan", "green", "magenta", "yellow", "red", "orange"]

  // "theme" first, then each of those the current theme defines.
  readonly property var available: {
    var list = ["theme"]
    for (var i = 0; i < root.names.length; i++)
      if (root.colors[root.names[i]] !== undefined) list.push(root.names[i])
    return list
  }

  function parse(text) {
    var found = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/.exec(lines[i])
      if (match) found[match[1]] = match[2]
    }
    return found
  }

  FileView {
    id: file
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.colors = root.parse(text())
    onFileChanged: reload()
  }

  // A theme switch reaches the shell as a pushed payload and the file may be
  // swapped under the watch, so also re-read shortly after the accent moves.
  Connections {
    target: Color
    function onAccentChanged() { reread.restart() }
  }

  Timer {
    id: reread
    interval: 400
    onTriggered: file.reload()
  }
}
