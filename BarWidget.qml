import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Reads a GPU's temperature and VRAM straight from sysfs.
//
// The card index is a per-widget setting (default 1, i.e. the dGPU on a
// typical iGPU + dGPU hybrid laptop). It is read from shell.json's layout
// entry for this widget via the base BarWidget's setting() helper, so a user
// can point it at a different card without editing the plugin:
//
//   "right": [ { "id": "gileshome.gpu", "card": 0 } ]
//
// We deliberately avoid Quickshell.Io's FileView: its FileView.qml resolves
// through the shell's config-folder import path, which blackholes paths
// outside the config folder, so a user plugin under
// ~/.config/omarchy/plugins/ can never see the FileView type ("FileView is
// not a type"). The bare Process / StdioCollector types resolve fine from
// anywhere, so we poll the three sysfs files with a short-lived `cat` instead.
//
// The hwmon subdirectory is discovered by scanning deviceDir/hwmon for the
// entry that contains a temp1_input file, so it works regardless of how the
// kernel named the card's hwmon instance (hwmon1, hwmon2, ...).
BarWidget {
  id: root
  moduleName: "gileshome.gpu"

  // card: drm card index to monitor. Default 1 = dGPU on hybrid setups;
  // override per-widget in shell.json (see comment above).
  readonly property int card: setting("card", 1)

  readonly property string deviceDir: "/sys/class/drm/card" + card + "/device"
  readonly property string vramUsedPath: deviceDir + "/mem_info_vram_used"
  readonly property string vramTotalPath: deviceDir + "/mem_info_vram_total"

  // Latest known values, in human units.
  property int tempC: 0
  property real vramUsedGiB: 0
  property real vramTotalGiB: 0
  property bool ready: false

  function toGiB(bytes) {
    return bytes / (1024 * 1024 * 1024)
  }

  // One `cat` over the temp + the two VRAM files; the lines arrive in order.
  property Process reader: Process {
    onExited: {
      var lines = (stdout.text || "").trim().split("\n")
      if (lines.length < 3) return
      // temp1_input is millidegrees; the two mem_info files are bytes.
      var t = Number(lines[0] || 0)
      if (!isNaN(t) && t > 0) root.tempC = Math.round(t / 1000)
      var u = Number(lines[1] || 0)
      if (!isNaN(u)) root.vramUsedGiB = root.toGiB(u)
      var total = Number(lines[2] || 0)
      if (!isNaN(total)) root.vramTotalGiB = root.toGiB(total)
      if (root.tempC > 0 && root.vramTotalGiB > 0) root.ready = true
    }
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
  }

  function refresh() {
    // Locate the card's hwmon temp file, then cat all three in one process.
    // A glob loop is used instead of `find -exec test` because the latter is
    // unreliable in the shell's Process context.
    reader.command = ["bash", "-c",
      "t=; " +
      "for d in \"$0/hwmon\"/hwmon*; do " +
      "  [ -f \"$d/temp1_input\" ] && { t=\"$d/temp1_input\"; break; }; " +
      "done; " +
      "cat -- \"$t\" \"$1\" \"$2\" 2>/dev/null",
      root.deviceDir,
      root.vramUsedPath,
      root.vramTotalPath]
    reader.running = true
  }

  // Re-read the card when the setting changes, and kick off the first poll.
  Component.onCompleted: refresh()
  onCardChanged: {
    ready = false
    tempC = 0
    vramUsedGiB = 0
    vramTotalGiB = 0
    refresh()
  }

  // sysfs values drift between inotify events, so poll on a fixed cadence.
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  visible: ready
  implicitWidth: ready ? labelRow.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: labelRow
    spacing: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter

    Text {
      text: "󰢮"
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      color: root.bar.barForeground
    }

    Text {
      textFormat: Text.PlainText
      text: root.ready
        ? root.tempC + "°C  " + Commons.I18n.formatNumber(root.vramUsedGiB, 1) + "/" + Commons.I18n.formatNumber(root.vramTotalGiB, 1) + " GiB"
        : "GPU --"
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      color: root.bar.barForeground
    }
  }
}
