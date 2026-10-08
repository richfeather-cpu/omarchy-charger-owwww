import QtQuick
import Quickshell
import Quickshell.Io

// Headless service. omarchy-shell creates this when the plugin is enabled
// and destroys it on disable or removal, which stops the watcher. No user
// systemd unit is installed, and this file never writes shell.json.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    // Injected by the shell after createObject. manifest.__sourceDir is how
    // a third-party plugin finds its own scripts and the bundled sound.
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null
    property string omarchyPath: ""

    readonly property string pluginId: (manifest && manifest.id)
        ? String(manifest.id)
        : "io.github.richfeather-cpu.omarchy-owww"

    readonly property string pluginDir: {
        var dir = (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
        return dir.replace(/\/$/, "")
    }

    readonly property string shellConfigPath: {
        var xdg = Quickshell.env("XDG_CONFIG_HOME")
        var base = (xdg && String(xdg).length > 0)
            ? String(xdg)
            : (String(Quickshell.env("HOME") || "") + "/.config")
        return base + "/omarchy/shell.json"
    }

    property bool configReady: false
    property bool destroying: false
    property bool expectExit: false
    property string appliedSignature: ""

    function fieldOf(entry, key) {
        if (!entry || !Object.prototype.hasOwnProperty.call(entry, key))
            return ""
        if (entry[key] === null || entry[key] === undefined)
            return ""
        return String(entry[key])
    }

    // null means "do not restart" (shell.json is mid-edit and invalid).
    function signatureFor(text) {
        var raw = String(text || "")
        if (!raw.trim())
            return "missing"
        var cfg
        try {
            cfg = JSON.parse(raw)
        } catch (e) {
            return null
        }
        if (!cfg || !Array.isArray(cfg.plugins))
            return "absent"
        for (var i = 0; i < cfg.plugins.length; i++) {
            var entry = cfg.plugins[i]
            if (!entry || String(entry.id || "") !== root.pluginId)
                continue
            return [
                "present",
                root.fieldOf(entry, "sound"),
                root.fieldOf(entry, "volume"),
                root.fieldOf(entry, "debounce"),
                root.fieldOf(entry, "poll")
            ].join("\n")
        }
        return "absent"
    }

    function stopWatcher() {
        crashTimer.stop()
        if (!watcher.running)
            return
        root.expectExit = true
        watcher.running = false
    }

    function restartWatcher() {
        if (root.destroying || !root.pluginDir)
            return
        crashTimer.stop()
        root.expectExit = watcher.running
        watcher.exec({
            command: ["bash", root.pluginDir + "/bin/owww"],
            environment: {
                OWWW_PLUGIN_DIR: root.pluginDir
            }
        })
    }

    function applyConfig(forceDefaults) {
        if (!root.pluginDir)
            return
        var sig = forceDefaults ? "missing" : root.signatureFor(shellConfigFile.text())
        if (sig === null) {
            if (!root.appliedSignature) {
                console.log("owww: shell.json did not parse; starting with defaults")
                sig = "missing"
            } else {
                console.log("owww: shell.json did not parse; keeping the current watcher")
                return
            }
        }
        if (sig === root.appliedSignature)
            return
        root.appliedSignature = sig
        if (sig === "absent") {
            console.log("owww: plugin entry gone; stopping watcher")
            root.stopWatcher()
            return
        }
        root.restartWatcher()
    }

    FileView {
        id: shellConfigFile
        path: root.shellConfigPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.configReady = true
            root.applyConfig(false)
        }
        onLoadFailed: function(error) {
            root.configReady = true
            console.log("owww: no shell.json yet (" + error + "); using defaults")
            root.applyConfig(true)
        }
        onFileChanged: reload()
    }

    Process {
        id: watcher
        stdout: SplitParser {
            onRead: function(line) { console.log("owww: " + line) }
        }
        stderr: SplitParser {
            onRead: function(line) { console.log("owww: " + line) }
        }
        onExited: function(exitCode, exitStatus) {
            if (root.destroying)
                return
            if (root.expectExit) {
                root.expectExit = false
                return
            }
            if (root.appliedSignature === "absent")
                return
            console.log("owww: watcher exited (" + exitCode + "); retrying in 5s")
            crashTimer.restart()
        }
    }

    Timer {
        id: crashTimer
        interval: 5000
        repeat: false
        onTriggered: root.restartWatcher()
    }

    onPluginDirChanged: {
        if (root.configReady)
            root.applyConfig(false)
    }

    Component.onDestruction: {
        root.destroying = true
        root.stopWatcher()
    }
}
