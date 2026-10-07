import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.nobledoodle.omarchroma"
  ipcTarget: "io.github.nobledoodle.omarchroma"
  manageIpc: false

  property var hostWidget: null
  property var anchorItem: null
  readonly property var barIdentity: hostWidget || root
  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") !== ""
    ? Quickshell.env("XDG_STATE_HOME") + "/hyprchroma"
    : Quickshell.env("HOME") + "/.local/state/hyprchroma"
  readonly property string dataDir: Quickshell.env("XDG_DATA_HOME") !== ""
    ? Quickshell.env("XDG_DATA_HOME") + "/hyprchroma"
    : Quickshell.env("HOME") + "/.local/share/hyprchroma"
  // Commands these run resolve from here, not from the PATH the shell happened
  // to inherit. They start unattended -- at login, and on every window event --
  // so a directory earlier in the ambient PATH holding something called jq or
  // hyprctl would be executed with nobody watching. Everything they call lives
  // in a root-owned system directory; the last entry is Omarchy's own. The
  // rest of the environment is preserved, so HOME and the session bus survive.
  // Fixed absolute identities. /usr/local/* is excluded because nothing
  // this plugin invokes lives there and it is the entry most often left
  // group-writable; the helpers launched below re-derive and verify their
  // own PATH regardless, so this is a floor rather than the whole defense.
  readonly property string trustedPath: "/usr/bin:/usr/share/omarchy/bin"

  readonly property string settingsPath: stateDir + "/settings.json"
  readonly property string statusPath: stateDir + "/status.json"

  // hyprchroma is a separate package and does all the actual work; this panel
  // only drives it. Without it every toggle would fail quietly and the panel
  // would look broken, so the state is checked on open and the panel offers to
  // install it instead of pretending it can do anything.
  property bool dependencyChecked: false
  property bool dependencyPresent: false
  property bool daemonRunning: false
  property bool installing: false
  readonly property bool ready: dependencyPresent && daemonRunning && !outdated

  // The service and this panel ship from one repository, so what the panel
  // expects is simply its own version -- read from the manifest beside it
  // rather than written down twice. They are still installed by different
  // things, "omarchy plugin update" and makepkg, so the installed service can
  // lag behind the checkout and this is what notices.
  property string expectedVersion: ""
  property string installedVersion: ""
  readonly property bool outdated: dependencyPresent && installedVersion !== ""
    && expectedVersion !== "" && root.olderThan(installedVersion, expectedVersion)

  FileView {
    id: manifestFile
    path: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName + "/manifest.json"
    printErrors: false
    // Watched, so "omarchy plugin update" lights the bar icon as soon as the
    // checkout moves ahead of the installed service, not at the next login.
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        root.expectedVersion = String(JSON.parse(text()).version || "")
      } catch (error) {
        root.expectedVersion = ""
      }
    }
  }

  // And the other side: pacman replacing the service's binary -- an update run
  // from a terminal rather than from here -- asks the version again, so the
  // alert clears without the panel having to be opened.
  FileView {
    id: serviceBinary
    path: "/usr/bin/hyprchroma"
    printErrors: false
    watchChanges: true
    onFileChanged: {
      reload()
      presenceProcess.running = true
    }
  }

  // Asked once as the shell starts, not only when the panel opens: the bar icon
  // shows a pending update, so it has to know about one without being clicked.
  Component.onCompleted: presenceProcess.running = true

  // Numeric compare, field by field. "1.10.0" is newer than "1.9.0", which a
  // string compare gets backwards.
  function olderThan(have, want) {
    var a = String(have).split("."), b = String(want).split(".")
    for (var i = 0; i < Math.max(a.length, b.length); i++) {
      var x = parseInt(a[i] || "0", 10), y = parseInt(b[i] || "0", 10)
      if (isNaN(x)) x = 0
      if (isNaN(y)) y = 0
      if (x !== y) return x < y
    }
    return false
  }

  // Asking hyprchroma its version cannot answer "is hyprchroma installed":
  // when the binary is absent the process never starts, and Quickshell emits
  // no started, runningChanged or exited signal for a process that never ran.
  // Nothing set dependencyChecked, so the panel that offers to install it
  // stayed hidden in exactly the case it exists for -- a machine without the
  // service. This asks a binary that is always there instead, and only runs
  // the version probe once it has said yes.
  Process {
    id: presenceProcess
    command: [ "/usr/bin/test", "-x", "/usr/bin/hyprchroma" ]
    environment: ({ PATH: root.trustedPath })
    onExited: function(code) {
      if (code === 0) {
        versionProcess.running = true
      } else {
        root.dependencyPresent = false
        root.dependencyChecked = true
        root.daemonRunning = false
        root.installedVersion = ""
        root.staleWindows = ({})
        root.staleApps = []
        root.darkReaderPending = []
      }
    }
  }

  Process {
    id: versionProcess
    command: [ "/usr/bin/hyprchroma", "--version" ]
    environment: ({ PATH: root.trustedPath })
    stdout: StdioCollector {
      waitForEnd: true
      // "hyprchroma 1.4.1" -> "1.4.1"
      onStreamFinished: {
        var match = /([0-9]+(?:\.[0-9]+)*)/.exec(String(text))
        root.installedVersion = match ? match[1] : ""
      }
    }
    onExited: function(code) {
      root.dependencyPresent = (code === 0)
      root.dependencyChecked = true
      if (root.dependencyPresent) {
        daemonProcess.running = true
        // Asked here rather than when the panel opens: the stale list comes
        // from the same binary, so it can only be asked once presence is
        // settled, and presence is settled asynchronously.
        root.refreshStaleApps()
      } else {
        root.daemonRunning = false
        root.installedVersion = ""
      }
    }
  }

  Process {
    id: daemonProcess
    command: [ "systemctl", "--user", "is-active", "--quiet", "hyprchromad.service" ]
    environment: ({ PATH: root.trustedPath })
    onExited: function(code) { root.daemonRunning = (code === 0) }
  }

  // Run in Omarchy's presented terminal, never inside omarchy-shell: this
  // authenticates, and a password prompt with nowhere to type is a hang. The
  // panel closes first so the terminal has the keyboard. Sentinels in the
  // runtime directory let the result be picked up after the panel is gone.
  // Installing and updating both run the same setup script, shipped with this
  // plugin, in Omarchy's presented terminal. It has to be a terminal: it asks
  // which optional frameworks you want, offers to install what those need, and
  // makepkg asks for a password -- none of which has anywhere to happen inside
  // omarchy-shell. The panel closes first so the terminal takes the keyboard.
  //
  // No sentinel files. An earlier version wrote .done/.failed markers into
  // $XDG_RUNTIME_DIR, falling back to /tmp -- a predictable name in a
  // world-writable directory, truncated with ":>", which is a symlink target
  // another account can plant. Nothing ever read them: onExited says when the
  // terminal finished and the version check that follows says whether it
  // worked.
  readonly property string setupScript:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName
      + "/bin/hyprchroma-setup"

  Process {
    id: installProcess
    command: [ "omarchy", "launch", "floating", "terminal", "with", "presentation", root.setupScript ]
    environment: ({ PATH: root.trustedPath })
    onExited: { root.installing = false; presenceProcess.running = true }
  }

  Process {
    id: restoreProcess
    environment: ({ PATH: root.trustedPath })
    onExited: settingsFile.reload()
  }

  // Putting one back is a single command, and it syncs on the way in, so the
  // framework is styled again by the time its row reappears.
  function restoreFramework(target) {
    if (restoreProcess.running) return
    restoreProcess.command = [ "/usr/bin/hyprchroma", "framework", "restore", target ]
    restoreProcess.running = true
  }

  Process {
    id: startDaemonProcess
    command: [ "systemctl", "--user", "enable", "--now", "hyprchromad.service" ]
    environment: ({ PATH: root.trustedPath })
    onExited: { root.installing = false; presenceProcess.running = true }
  }

  function installDependency() {
    if (root.installing) return
    root.installing = true
    if (root.dependencyPresent && !root.outdated && !root.daemonRunning) {
      // Only the service needs starting; that takes no password and no terminal.
      startDaemonProcess.running = true
      return
    }
    // Missing or too old: the same build either way.
    root.close()
    installProcess.running = true
  }

  // Applications with a window open that started before the palette was last
  // written, so they are still drawing the previous theme. Kept in the panel
  // rather than only in a notification: a notification is gone in seconds, and
  // this is a list you work through at your own pace.
  property var staleApps: []
  // How many windows each has open, since that is what there is to close. An
  // app missing from it -- a service older than the counts -- has one.
  property var staleWindows: ({})
  // Browsers whose Dark Reader is waiting for them to close: its storage cannot
  // be written under an open browser. Not stale windows -- Omarchy themes the
  // browser itself -- but still a thing to close, so the list below names them.
  property var darkReaderPending: []
  readonly property int staleWindowCount: {
    var counts = root.staleWindows
    var total = 0
    for (var i = 0; i < root.staleApps.length; i++) total += root.windowsOf(root.staleApps[i], counts)
    return total
  }

  function windowsOf(name, counts) {
    var count = (counts || root.staleWindows)[name]
    return (typeof count === "number" && count >= 1 && count <= 999 && count === Math.floor(count))
      ? count : 1
  }

  // The service keeps only letters, digits and " .+-_" in a name, but status.json
  // can be written by anything this account runs -- a Flatpak app granted
  // ~/.local/state among them -- so what is shown is checked again here, and
  // drawn as plain text: as rich text, an <img> in a planted name had the shell
  // fetch whatever address it gave.
  readonly property int staleListed: 256

  function validStaleName(name) {
    return typeof name === "string" && name.length > 0 && name.length <= 64
      && !/[\u0000-\u001f\u007f<>&]/.test(name)
  }

  // Everything the user has to close for the new theme, one entry per
  // application: stale windows first, then browsers Dark Reader waits on. A
  // browser in both is named once, with both reasons.
  readonly property var restartItems: {
    var items = []
    var key = function(name) { return String(name).toLowerCase().replace(/[^a-z0-9]/g, "") }
    var seen = {}
    for (var i = 0; i < root.staleApps.length; i++) {
      var name = root.staleApps[i]
      seen[key(name)] = items.length
      items.push({ name: name, windows: root.windowsOf(name, root.staleWindows), darkReader: false })
    }
    for (var j = 0; j < root.darkReaderPending.length; j++) {
      var browser = root.darkReaderPending[j]
      var at = seen[key(browser)]
      if (at !== undefined) items[at].darkReader = true
      else items.push({ name: browser, windows: 0, darkReader: true })
    }
    return items
  }
  readonly property int restartCount: {
    var total = 0
    for (var i = 0; i < root.restartItems.length; i++)
      total += Math.max(1, root.restartItems[i].windows)
    return total
  }

  function restartDetail(item) {
    var parts = []
    if (item.windows > 0) parts.push(root.windowsPhrase(item.windows))
    if (item.darkReader) parts.push("Dark Reader waits")
    return parts.join(" · ")
  }

  function windowsPhrase(count) {
    return count === 1 ? "1 window" : count + " windows"
  }

  // The guide replaces the panel body rather than sitting inside it: the list
  // is as long as the user has windows open, and growing the panel by one row
  // per application would push the frameworks off the screen.
  property bool guideOpen: false
  // The gear's view: density and font size, in place of everything below the
  // header. Mutually exclusive with the guide, so there is one thing on screen.
  property bool settingsOpen: false
  // The accent synchronized apps use: "theme" or a palette color's name. Held
  // here only to show which swatch is chosen; the service owns the setting.
  property string accentChoice: "theme"

  ThemePalette { id: themePalette }
  readonly property bool mainView: !root.guideOpen && !root.settingsOpen

  // However many are open, the panel stays a readable size and says how many
  // it did not name.
  readonly property int staleShown: 8

  property string activeTarget: ""

  // One list drives both the rows and the keyboard shortcuts, so the digit a
  // row shows is always the digit that toggles it.
  //
  // Digits rather than initials: PanelKeyCatcher already consumes h/j/k/l for
  // cursor movement and x for delete, so "k" cannot reach this panel to mean
  // KDE; and "q" reads as quit in almost every keyboard UI, which is a poor
  // thing to wire to a toggle that reverts the framework it switches off.
  property var removedTargets: []

  // Every framework this knows about, and the ones left after the user's
  // removals. Rows are numbered by position in the visible list, so removing
  // one renumbers the rest rather than leaving a gap.
  readonly property var visibleFrameworks:
    allFrameworks.filter(function(entry) {
      return root.removedTargets.indexOf(root.targetKey(entry.target)) === -1
    })
  readonly property var hiddenFrameworks:
    allFrameworks.filter(function(entry) {
      return root.removedTargets.indexOf(root.targetKey(entry.target)) !== -1
    })

  readonly property var allFrameworks: [
    { target: "gtk", label: "GTK and GNOME", icon: "󰍛" },
    { target: "qt-kde", label: "Qt and KDE", icon: "󰖯" },
    { target: "dark-reader", label: "Dark Reader", icon: "󰈈" },
    { target: "flatpak", label: "Flatpak apps", icon: "󰏗" },
    { target: "browsers", label: "Additional browsers", icon: "󰖟" }
  ]

  // Flatpak and additional browsers are opt-in -- one widens what every
  // sandboxed app may read, the other writes into browser profiles -- so they
  // alone are off unless settings record them on.
  property var enabledTargets: ({
    gtk: true,
    qtKde: true,
    darkReader: true,
    flatpak: false,
    browsers: false
  })

  function targetKey(target) {
    if (target === "qt-kde") return "qtKde"
    if (target === "dark-reader") return "darkReader"
    return target
  }

  function targetEnabled(target) {
    var key = targetKey(target)
    if (key === "flatpak" || key === "browsers") return enabledTargets[key] === true
    return enabledTargets[key] !== false
  }

  function setTargetEnabled(target, enabled) {
    if (refreshProcess.running) return
    var key = targetKey(target)
    var next = {
      gtk: enabledTargets.gtk !== false,
      qtKde: enabledTargets.qtKde !== false,
      darkReader: enabledTargets.darkReader !== false,
      flatpak: enabledTargets.flatpak === true,
      browsers: enabledTargets.browsers === true
    }
    next[key] = enabled
    enabledTargets = next
    activeTarget = target
    refreshProcess.command = [
      "/usr/bin/hyprchroma",
      "--target=" + target,
      "--set-enabled=" + (enabled ? "true" : "false"),
      "--notify"
    ]
    refreshProcess.running = true
  }

  function refresh(target) {
    if (refreshProcess.running) return
    activeTarget = target
    refreshProcess.command = [
      "/usr/bin/hyprchroma",
      "--target=" + target,
      "--force",
      "--notify"
    ]
    refreshProcess.running = true
  }

  // "r" matches the convention PanelKeyCatcher documents for refresh; the
  // digits match each row's position, which the row displays.
  function handleKey(text) {
    var key = (text || "").toLowerCase()
    // "i" only does anything while the panel is offering it, so it cannot be
    // pressed by accident into an install nobody asked for.
    if (key === "i" && root.dependencyChecked && !root.ready) {
      root.installDependency()
      return
    }
    // Settings has no key of its own: digits and "r" belong to the main view.
    if (root.settingsOpen) return
    // Nothing below this can work without hyprchroma: the guide lists
    // applications a framework toggle left stale, and there is no framework
    // toggle without the service. A key that would open it is ignored rather
    // than opening an always-empty screen.
    if (!root.ready) return
    // "/" rather than "?" so no shift is needed, and rather than "h" because
    // PanelKeyCatcher consumes h/j/k/l before a panel sees them -- the same
    // reason the framework rows are numbered.
    if (key === "/") {
      if (root.hiddenFrameworks.length > 0) root.guideOpen = !root.guideOpen
      return
    }
    // While the guide is up, a digit means one of the removed frameworks listed
    // there -- not one of the toggles, whose rows are not on screen.
    if (root.guideOpen) {
      var back = parseInt(key, 10) - 1
      if (back >= 0 && back < root.hiddenFrameworks.length) {
        root.restoreFramework(root.hiddenFrameworks[back].target)
      }
      return
    }
    if (key === "r") {
      root.refresh("all")
      return
    }
    var index = parseInt(key, 10) - 1
    if (index >= 0 && index < root.visibleFrameworks.length) {
      var target = root.visibleFrameworks[index].target
      root.setTargetEnabled(target, !root.targetEnabled(target))
    }
  }

  function refreshStaleApps() {
    // Same absent binary, same silent non-start. Nothing to ask until the
    // presence probe has said the service is there.
    if (!root.dependencyPresent) { root.staleWindows = ({}); root.staleApps = []; return }
    if (!staleProcess.running) staleProcess.running = true
  }

  // One app per line, "Vivaldi (2 windows)" where it has more than one.
  function applyStaleApps(output) {
    var names = []
    var counts = {}
    var lines = (output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      var match = /^(.*\S) \(([0-9]+) windows\)$/.exec(line)
      var name = match ? match[1] : line
      if (!root.validStaleName(name) || names.length >= root.staleListed) continue
      names.push(name)
      counts[name] = match ? parseInt(match[2], 10) : 1
    }
    root.staleWindows = counts
    root.staleApps = names
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: refreshProcess
    environment: ({ PATH: root.trustedPath })
    onExited: function() {
      root.activeTarget = ""
      settingsFile.reload()
      root.refreshStaleApps()
    }
  }

  // Measured against the last recorded sync rather than the last theme switch:
  // the question this answers is "did this application start before the palette
  // it is drawing was written", which a toggle changes just as a theme does.
  Process {
    id: staleProcess
    command: [ "/usr/bin/hyprchroma", "stale-apps" ]
    environment: ({ PATH: root.trustedPath })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStaleApps(text)
    }
  }

  // The list of what to close is on the panel itself, so it is asked for as the
  // panel opens (presence first, which asks for it once settled).
  onOpenedChanged: if (root.opened) presenceProcess.running = true

  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        var frameworks = parsed.frameworks || {}
        var picked = parsed.accent
        root.accentChoice = themePalette.names.indexOf(picked) >= 0 ? picked : "theme"
        // Frameworks the user said they did not want. Off is a toggle; removed
        // takes the row out of the panel entirely.
        root.removedTargets = Array.isArray(parsed.removed) ? parsed.removed : []
        root.enabledTargets = {
          gtk: frameworks.gtk !== false,
          qtKde: frameworks.qtKde !== false,
          darkReader: frameworks.darkReader !== false,
          flatpak: frameworks.flatpak === true,
          browsers: frameworks.browsers === true
        }
      } catch (error) {
        root.accentChoice = "theme"
        root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, flatpak: false, browsers: false }
      }
    }
    onLoadFailed: {
      root.accentChoice = "theme"
      root.enabledTargets = { gtk: true, qtKde: true, darkReader: true, flatpak: false, browsers: false }
    }
    onFileChanged: reload()
  }

  // The applications still showing the previous theme, as the service keeps
  // them: after each sync, and each time a window opens or closes. Watched
  // rather than asked for, so the bar icon's count follows an application
  // being closed without anything here polling.
  FileView {
    id: statusFile
    path: root.statusPath
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        var status = JSON.parse(text())
        var waiting = status.darkReaderPending
        root.darkReaderPending = Array.isArray(waiting)
          ? waiting.filter(root.validStaleName).slice(0, 16) : []
        var names = status.staleApps
        if (Array.isArray(names)) {
          var counts = status.staleWindows
          root.staleWindows = (counts && typeof counts === "object" && !Array.isArray(counts)) ? counts : ({})
          root.staleApps = names.filter(root.validStaleName).slice(0, root.staleListed)
        }
      } catch (error) {
        // A partly written or foreign file: keep the last list rather than
        // flicker the count to zero.
      }
    }
    onFileChanged: reload()
  }

  // ---- Display settings (shell.json, set from the gear view) ----
  // Roomy is a little under the shell's stock panel size; the others shrink spacing and, half
  // as fast, text, so Compact stays readable. The font size scales text on top.
  readonly property string density: String(setting("density", "normal"))
  readonly property string fontSize: String(setting("fontSize", "normal"))
  readonly property real densityScale: density === "compact" ? 0.5 : (density === "roomy" ? 0.8 : 0.65)
  readonly property real fontScale: (0.5 + 0.5 * densityScale)
    * (fontSize === "small" ? 0.9 : (fontSize === "large" ? 1.1 : 1.0))
  readonly property real fontDisplay: Math.round(Style.font.display * fontScale)
  readonly property real fontTitle: Math.round(Style.font.title * fontScale)
  readonly property real fontBody: Math.round(Style.font.body * fontScale)
  readonly property real fontCaption: Math.max(9, Math.round(Style.font.caption * fontScale))

  function sp(px) { return Style.space(px * densityScale) }

  function setAccent(name) {
    if (refreshProcess.running) return
    root.accentChoice = name
    root.activeTarget = "accent"
    refreshProcess.command = [
      "/usr/bin/hyprchroma",
      "--set-accent=" + name,
      "--notify"
    ]
    refreshProcess.running = true
  }

  function setSetting(key, value) {
    Quickshell.execDetached(["omarchy", "bar", "set", root.moduleName, key, JSON.stringify(value), "--json"])
  }

  // The look follows Tandem and omaudiopanel: a hero header with the version
  // and a repository link, dim-icon section titles in letter-spaced capitals,
  // outlined cards, and one highlight color -- the theme's accent -- for
  // switches, hover and the version pill.
  readonly property color fg: root.bar ? root.bar.foreground : Color.popups.text
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent
  readonly property string repoUrl: "https://github.com/thevideinfra/omarchroma"
  readonly property int enabledCount: root.visibleFrameworks.filter(function(entry) {
    return root.targetEnabled(entry.target)
  }).length

  // Section title: a dim icon, then the bold title.
  component SectionLabel: Row {
    id: section
    property string icon: ""
    property string text: ""
    spacing: root.sp(7)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: section.icon
      color: root.fg
      opacity: 0.65
      font.family: root.fontFamily
      font.pixelSize: Math.round(root.fontCaption * 1.2)
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: section.text
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: root.fontCaption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  // Compact on/off switch tinted in the accent. Display only: the row it sits
  // in takes the click.
  component AccentSwitch: Item {
    id: sw
    property bool checked: false
    property bool busy: false

    implicitWidth: root.sp(34)
    implicitHeight: root.sp(18)
    opacity: sw.busy ? 0.5 : 1.0

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: sw.checked ? Util.alpha(root.accent, 0.3) : Util.alpha(root.fg, 0.1)
      border.width: 1
      border.color: sw.checked ? root.accent : Util.alpha(root.fg, 0.25)
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        width: parent.height - root.sp(6)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: sw.checked ? parent.width - width - (parent.height - height) / 2 : (parent.height - height) / 2
        color: sw.checked ? root.accent : Qt.darker(root.fg, 1.4)
        Behavior on x { NumberAnimation { duration: 120 } }
        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }
  }

  // The theme's own accent, then the other colors of its palette, each drawn in
  // its real color. The chosen one is ringed.
  component AccentPicker: Flow {
    spacing: root.sp(5)

    Repeater {
      model: themePalette.available

      Rectangle {
        id: swatch
        required property string modelData
        readonly property bool isTheme: modelData === "theme"
        // A saved color the theme no longer defines shows as the theme's own.
        readonly property bool chosen: isTheme
          ? themePalette.available.indexOf(root.accentChoice) < 0 || root.accentChoice === "theme"
          : root.accentChoice === modelData
        width: isTheme ? themeLabel.implicitWidth + root.sp(30) : root.sp(23)
        height: root.sp(23)
        radius: height / 2
        color: isTheme ? Util.alpha(root.fg, 0.06) : themePalette.colors[modelData]
        border.width: chosen ? 2 : 1
        border.color: chosen ? root.fg : Util.alpha(root.fg, isTheme ? 0.25 : 0.15)

        // The theme entry is a pill with a dot in the theme's own accent.
        Rectangle {
          visible: swatch.isTheme
          anchors.left: parent.left
          anchors.leftMargin: root.sp(7)
          anchors.verticalCenter: parent.verticalCenter
          width: root.sp(11)
          height: width
          radius: width / 2
          color: themePalette.colors.accent !== undefined ? themePalette.colors.accent : Color.accent
        }

        Text {
          id: themeLabel
          visible: swatch.isTheme
          anchors.right: parent.right
          anchors.rightMargin: root.sp(8)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Theme"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          font.bold: swatch.chosen
        }

        MouseArea {
          id: swatchMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setAccent(swatch.modelData)
        }

        PanelToolTip {
          visible: swatchMouse.containsMouse
          text: swatch.isTheme ? "Follow the theme's colors"
            : swatch.modelData.charAt(0).toUpperCase() + swatch.modelData.slice(1)
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // Equal-width choice boxes; the chosen one is tinted and outlined in the
  // accent.
  component Segmented: Grid {
    id: segmented
    property var choices: []
    property var selected
    signal picked(var value)

    spacing: root.sp(6)
    readonly property real cellWidth: (width - (columns - 1) * spacing) / columns

    Repeater {
      model: segmented.choices

      Rectangle {
        id: choice
        required property var modelData
        readonly property bool chosen: segmented.selected === modelData.value
        width: segmented.cellWidth
        implicitHeight: choiceText.implicitHeight + root.sp(12)
        radius: root.sp(7)
        color: chosen
          ? Util.alpha(root.accent, 0.12)
          : Util.alpha(root.fg, choiceMouse.containsMouse ? 0.09 : 0.05)
        border.width: chosen ? 2 : 1
        border.color: chosen ? root.accent : Util.alpha(root.fg, 0.12)

        Text {
          id: choiceText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: choice.modelData.label
          color: choice.chosen ? root.accent : root.fg
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          font.bold: choice.chosen
        }

        MouseArea {
          id: choiceMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: segmented.picked(choice.modelData.value)
        }
      }
    }
  }

  // Outlined button: icon, label, and the accent on hover. `alert` lights it
  // in the theme's alert color, for a service that is behind this panel.
  component ActionCard: Rectangle {
    id: card
    property string iconText: ""
    property string text: ""
    property bool alert: false
    readonly property color alertColor: root.bar ? root.bar.urgent : Color.urgent
    signal clicked()

    implicitHeight: cardRow.implicitHeight + root.sp(14)
    radius: root.sp(7)
    opacity: card.enabled ? 1.0 : 0.5
    color: card.alert
      ? Util.alpha(card.alertColor, 0.30)
      : Util.alpha(root.fg, cardMouse.containsMouse ? 0.09 : 0.05)
    border.width: card.alert || (cardMouse.containsMouse && card.enabled) ? 2 : 1
    border.color: card.alert ? card.alertColor
      : (cardMouse.containsMouse && card.enabled ? root.accent : Util.alpha(root.fg, 0.12))

    Row {
      id: cardRow
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: root.sp(10)
      anchors.right: parent.right
      anchors.rightMargin: root.sp(10)
      spacing: root.sp(8)

      Text {
        visible: card.iconText !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: card.iconText
        color: cardMouse.containsMouse && card.enabled ? root.accent : root.fg
        opacity: 0.85
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - (card.iconText !== "" ? root.sp(26) : 0)
        textFormat: Text.PlainText
        text: card.text
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: card.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: card.clicked()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Width gives up half as much as spacing, so labels keep fitting.
    contentWidth: panel.fittedContentWidth(Math.round(Style.space(320) * (0.5 + 0.5 * root.densityScale)))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Escape leaves the guide first, so it never strands the user on a view
      // they cannot back out of.
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false
        else if (root.guideOpen) root.guideOpen = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleKey(text) }

      Column {
        id: content
        width: parent.width
        spacing: root.sp(10)

        // ---------- Hero: icon, name and status, version, repository ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰏘"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontDisplay
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          // Swaps everything below the header for the settings view.
          Text {
            id: gearButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.settingsOpen ? "󰅖" : "󰒓"
            // Larger than the header text and accent on hover, so it reads as
            // a control rather than decoration.
            color: gearMouse.containsMouse || root.settingsOpen ? root.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontTitle * 1.45)
            opacity: gearMouse.containsMouse || root.settingsOpen ? 1.0 : 0.85

            MouseArea {
              id: gearMouse
              anchors.fill: parent
              anchors.margins: -root.sp(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.settingsOpen = !root.settingsOpen
                root.guideOpen = false
              }
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: root.sp(12)
            anchors.right: gearButton.left
            anchors.rightMargin: root.sp(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.sp(2)

            Item {
              width: parent.width
              implicitHeight: Math.max(titleText.implicitHeight, infoRow.implicitHeight)

              Text {
                id: titleText
                anchors.left: parent.left
                anchors.right: infoRow.left
                anchors.rightMargin: root.sp(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "omarchroma"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: root.fontTitle
                font.bold: true
                elide: Text.ElideRight
              }

              Row {
                id: infoRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.sp(8)

                Rectangle {
                  visible: root.expectedVersion !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  width: versionText.implicitWidth + root.sp(10)
                  height: versionText.implicitHeight + root.sp(4)
                  radius: height / 2
                  color: Util.alpha(root.accent, 0.15)
                  border.width: 1
                  border.color: Util.alpha(root.accent, 0.45)

                  Text {
                    id: versionText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "v" + root.expectedVersion
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    font.bold: true
                  }
                }

                // Opens the repository in the browser.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: ""
                  color: repoMouse.containsMouse ? root.accent : root.fg
                  opacity: repoMouse.containsMouse ? 1.0 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody

                  MouseArea {
                    id: repoMouse
                    anchors.fill: parent
                    anchors.margins: -root.sp(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(["xdg-open", root.repoUrl])
                  }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: refreshProcess.running
                ? (root.targetEnabled(root.activeTarget) ? "SYNCHRONIZING " : "REVERTING ")
                  + String(root.activeTarget).toUpperCase() + "…"
                : (root.ready
                    ? root.enabledCount + " OF " + root.visibleFrameworks.length + " ACTIVE"
                    : (!root.dependencyChecked ? ""
                        : (!root.dependencyPresent ? "SERVICE NOT INSTALLED"
                            : (root.outdated ? "UPDATE AVAILABLE" : "SERVICE NOT RUNNING"))))
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.letterSpacing: 0.8
              elide: Text.ElideRight
            }
          }
        }

        PanelSeparator {
          foreground: root.fg
        }

        // ---------- Settings ----------
        Column {
          id: settingsView
          visible: root.settingsOpen
          width: content.width
          spacing: root.sp(10)

          ActionCard {
            width: settingsView.width
            text: "Back"
            iconText: "󰌍"
            onClicked: root.settingsOpen = false
          }

          SectionLabel {
            icon: ""
            text: "COLOR"
          }

          AccentPicker { width: settingsView.width }

          Text {
            width: settingsView.width
            text: "Tints windows and headers, highlights selections and accents in synchronized apps. Doesn't change this panel."
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            wrapMode: Text.WordWrap
          }

          SectionLabel {
            icon: "\uf1fc"
            text: "DENSITY"
          }

          Segmented {
            width: settingsView.width
            columns: 3
            choices: [
              { value: "compact", label: "Compact" },
              { value: "normal", label: "Normal" },
              { value: "roomy", label: "Roomy" }
            ]
            selected: root.density
            onPicked: function(value) { root.setSetting("density", value) }
          }

          SectionLabel {
            icon: "\uf031"
            text: "FONT SIZE"
          }

          Segmented {
            width: settingsView.width
            columns: 3
            choices: [
              { value: "small", label: "Small" },
              { value: "normal", label: "Normal" },
              { value: "large", label: "Large" }
            ]
            selected: root.fontSize
            onPicked: function(value) { root.setSetting("fontSize", value) }
          }
        }

        // ---------- Removed frameworks, to put back ----------
        Column {
          id: guide
          visible: root.guideOpen && !root.settingsOpen
          width: content.width
          spacing: root.sp(8)

          SectionLabel {
            icon: "󰆴"
            text: "REMOVED"
          }

          // Removing a framework takes its row out of the panel, so this is the only
          // place it still exists to be put back. Kept behind the same key as the
          // close list rather than given a view of its own: both are things you deal
          // with occasionally, and neither belongs in the panel body.
          Text {
            visible: root.hiddenFrameworks.length > 0
            width: guide.width
            text: "Removed — press the number to put one back"
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
          }

          Repeater {
            model: root.hiddenFrameworks
            delegate: Rectangle {
              id: gone
              required property var modelData
              required property int index
              width: guide.width
              height: Math.max(Math.round(Style.spacing.controlHeight * root.densityScale), goneRow.implicitHeight + root.sp(8))
              radius: root.sp(7)
              color: Util.alpha(root.fg, goneMouse.containsMouse ? 0.09 : 0.05)
              border.width: goneMouse.containsMouse ? 2 : 1
              border.color: goneMouse.containsMouse ? root.accent : Util.alpha(root.fg, 0.12)

              Row {
                id: goneRow
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sp(10)
                anchors.right: parent.right
                anchors.rightMargin: root.sp(10)
                spacing: root.sp(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: gone.modelData.icon
                  width: root.sp(22)
                  horizontalAlignment: Text.AlignHCenter
                  color: root.fg
                  opacity: 0.65
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - root.sp(22) - goneKey.width - 2 * parent.spacing
                  textFormat: Text.PlainText
                  text: gone.modelData.label
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody
                  elide: Text.ElideRight
                }

                Rectangle {
                  id: goneKey
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(height, goneKeyText.implicitWidth + root.sp(8))
                  height: goneKeyText.implicitHeight + root.sp(4)
                  radius: root.sp(4)
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(root.fg, 0.25)

                  Text {
                    id: goneKeyText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: String(gone.index + 1)
                    color: Color.muted
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                  }
                }
              }

              MouseArea {
                id: goneMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.restoreFramework(gone.modelData.target)
              }
            }
          }

          ActionCard {
            width: guide.width
            text: "Back  (/)"
            iconText: "󰌍"
            onClicked: root.guideOpen = false
          }
        }

        // Until hyprchroma exists there is exactly one thing to do from this
        // panel, so it gets exactly one control: the header above already
        // says what panel this is, and this button says the one action
        // available, in the same "Label  (key)" shape as the buttons below
        // it once the service is ready. Everything below this block -- the
        // framework toggles, the separator, refresh, the close-apps count --
        // is real only once the service is; each is gated on root.ready for
        // the same reason this replaces the old descriptive sentence.
        //
        // Lit in the theme's alert color while the service is behind this
        // panel -- the color the bar icon takes, since this is what clears it.
        ActionCard {
          visible: root.mainView && root.dependencyChecked && !root.ready
          width: content.width
          enabled: !root.installing
          text: root.installing
            ? "Working..."
            : (!root.dependencyPresent
                ? "Install  (i)"
                : root.outdated ? "Update  (i)" : "Start  (i)")
          alert: root.outdated
          onClicked: root.installDependency()
        }

        // ---------- Frameworks ----------
        Item {
          visible: root.mainView && root.ready
          width: content.width
          implicitHeight: Math.max(frameworksLabel.implicitHeight, syncButton.implicitHeight)

          SectionLabel {
            id: frameworksLabel
            icon: "󰏘"
            text: "FRAMEWORKS"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          // Sync everything that is switched on, now. Also the "r" key.
          Text {
            id: syncButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰑐"
            color: syncMouse.containsMouse && !refreshProcess.running ? root.accent : root.fg
            opacity: refreshProcess.running ? 0.4 : (syncMouse.containsMouse ? 1.0 : 0.7)
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontTitle * 1.2)

            MouseArea {
              id: syncMouse
              anchors.fill: parent
              anchors.margins: -root.sp(4)
              hoverEnabled: true
              enabled: !refreshProcess.running
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh("all")
            }

            PanelToolTip {
              visible: syncMouse.containsMouse
              text: "Sync everything now  (r)"
              fontFamily: root.fontFamily
            }
          }
        }

        Repeater {
          model: root.visibleFrameworks

          delegate: Rectangle {
            id: row
            visible: root.mainView && root.ready
            required property var modelData
            required property int index
            width: content.width
            height: visible ? Math.max(Math.round(Style.spacing.controlHeight * root.densityScale), rowInner.implicitHeight + root.sp(8)) : 0
            radius: root.sp(7)
            color: Util.alpha(root.fg, rowMouse.containsMouse ? 0.09 : 0.05)
            border.width: 1
            border.color: root.targetEnabled(row.modelData.target)
              ? Util.alpha(root.accent, rowMouse.containsMouse ? 0.7 : 0.35)
              : Util.alpha(root.fg, 0.12)

            Row {
              id: rowInner
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: root.sp(10)
              anchors.right: parent.right
              anchors.rightMargin: root.sp(10)
              spacing: root.sp(10)

              Text {
                id: icon
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.modelData.icon
                width: root.sp(22)
                horizontalAlignment: Text.AlignHCenter
                color: root.targetEnabled(row.modelData.target) ? root.accent : root.fg
                opacity: root.targetEnabled(row.modelData.target) ? 1.0 : 0.65
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
              }

              Text {
                id: label
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - icon.width - toggle.width - keyHint.width - 3 * parent.spacing
                textFormat: Text.PlainText
                text: row.modelData.label
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                elide: Text.ElideRight
              }

              // The key that toggles this row, shown so the shortcut is
              // discoverable without reading the README.
              Rectangle {
                id: keyHint
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(height, keyHintText.implicitWidth + root.sp(8))
                height: keyHintText.implicitHeight + root.sp(4)
                radius: root.sp(4)
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(root.fg, 0.25)

                Text {
                  id: keyHintText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: String(row.index + 1)
                  color: Color.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                }
              }

              AccentSwitch {
                id: toggle
                anchors.verticalCenter: parent.verticalCenter
                checked: root.targetEnabled(row.modelData.target)
                busy: refreshProcess.running
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setTargetEnabled(row.modelData.target, !root.targetEnabled(row.modelData.target))
            }
          }
        }

        Text {
          visible: root.mainView && root.ready
          text: "Switching one off restores how it looked before Omarchroma."
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        // Gated on root.ready, not just the main view: these act on a running
        // service, and with none installed they were showing "Refresh
        // enabled" and "Nothing to close" over an otherwise empty panel --
        // controls for a thing that does not exist yet.
        PanelSeparator {
          visible: root.mainView && root.ready
          foreground: root.fg
        }

        // ---------- What to close for the new theme ----------
        Item {
          visible: root.mainView && root.ready
          width: content.width
          implicitHeight: Math.max(restartLabel.implicitHeight, restartBadge.implicitHeight)

          SectionLabel {
            id: restartLabel
            icon: "󰖯"
            text: "CLOSE TO APPLY"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Rectangle {
            id: restartBadge
            visible: root.restartCount > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            readonly property color alertColor: root.bar ? root.bar.urgent : Color.urgent
            width: Math.max(height, restartBadgeText.implicitWidth + root.sp(10))
            height: restartBadgeText.implicitHeight + root.sp(4)
            radius: height / 2
            color: Util.alpha(alertColor, 0.15)
            border.width: 1
            border.color: Util.alpha(alertColor, 0.45)

            Text {
              id: restartBadgeText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: String(root.restartCount)
              color: restartBadge.alertColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: true
            }
          }
        }

        // Nothing waiting is said once, as a row, rather than leaving a heading
        // over empty space.
        Rectangle {
          visible: root.mainView && root.ready && root.restartItems.length === 0
          width: content.width
          height: Math.max(Math.round(Style.spacing.controlHeight * root.densityScale),
                           upToDate.implicitHeight + root.sp(8))
          radius: root.sp(7)
          color: Util.alpha(root.fg, 0.05)
          border.width: 1
          border.color: Util.alpha(root.fg, 0.12)

          Row {
            id: upToDate
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: root.sp(10)
            spacing: root.sp(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: root.sp(22)
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "󰄬"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontBody
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Everything shows the current theme"
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
            }
          }
        }

        Repeater {
          model: root.restartItems.slice(0, root.staleShown)

          delegate: Rectangle {
            id: waiting
            required property var modelData
            visible: root.mainView && root.ready
            readonly property color alertColor: root.bar ? root.bar.urgent : Color.urgent
            width: content.width
            height: visible ? Math.max(Math.round(Style.spacing.controlHeight * root.densityScale),
                                       waitingRow.implicitHeight + root.sp(8)) : 0
            radius: root.sp(7)
            color: Util.alpha(root.fg, 0.05)
            border.width: 1
            border.color: Util.alpha(waiting.alertColor, 0.35)

            Row {
              id: waitingRow
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: root.sp(10)
              anchors.right: parent.right
              anchors.rightMargin: root.sp(10)
              spacing: root.sp(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: root.sp(22)
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: "●"
                color: waiting.alertColor
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                id: waitingName
                width: parent.width - root.sp(22) - waitingDetail.implicitWidth - 2 * parent.spacing
                textFormat: Text.PlainText
                text: waiting.modelData.name
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                elide: Text.ElideRight
              }

              Text {
                id: waitingDetail
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.restartDetail(waiting.modelData)
                color: root.fg
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
              }
            }
          }
        }

        Text {
          visible: root.mainView && root.ready && root.restartItems.length > root.staleShown
          width: content.width
          text: "and " + (root.restartItems.length - root.staleShown) + " more"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
        }

        // Where a removed framework is put back: the only trace it leaves.
        Text {
          visible: root.mainView && root.ready && root.hiddenFrameworks.length > 0
          width: content.width
          textFormat: Text.PlainText
          text: root.hiddenFrameworks.length + " removed \u00b7 restore  (/)"
          color: removedMouse.containsMouse ? root.accent : Color.muted
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption

          MouseArea {
            id: removedMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.guideOpen = true
          }
        }
      }
    }
  }
}
