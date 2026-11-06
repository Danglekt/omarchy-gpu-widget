import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Reads a GPU's temperature and VRAM straight from sysfs, for an AMD GPU
// (amdgpu). Designed for the discrete GPU (dGPU) on a hybrid iGPU + dGPU
// laptop, e.g. an AMD Radeon RX 9050 / 9060 XT.
//
// Card selection
//   The card index is a per-widget setting read from shell.json's layout
//   entry for this widget (the base BarWidget injects it as `settings`):
//
//     "right": [ { "id": "gileshome.gpu", "card": 0 } ]
//
//   When "card" is omitted (the default), the widget auto-detects a
//   supported AMD GPU: it enumerates /sys/class/drm/cardN, keeps the ones
//   driven by amdgpu, and picks the one with the largest reported VRAM —
//   which is the dGPU on a hybrid machine (a 16 GiB dGPU vs a 512 MiB
//   iGPU), and the only GPU on a dGPU-only desktop. Auto-detection runs
//   once at startup; to pin a specific card, set "card" explicitly.
//
// Reading the values
//   Temperature, VRAM used, and VRAM total are each read independently with
//   their own short-lived process, so a missing or unreadable sensor or file
//   cannot shift the other values or hide a reading that is still available.
//   Each metric keeps its last good value and an "available" flag; the widget
//   renders whatever is available and shows an "unavailable" state only when
//   nothing is.
//
//   We deliberately avoid Quickshell.Io's FileView: its FileView.qml resolves
//   through the shell's config-folder import path, which blackholes paths
//   outside the config folder, so a user plugin under
//   ~/.config/omarchy/plugins/ can never see the FileView type ("FileView is
//   not a type"). The bare Process / StdioCollector types resolve fine from
//   anywhere, so we poll the sysfs files with a short-lived `cat` instead.
//
//   The hwmon subdirectory is discovered by scanning deviceDir/hwmon for the
//   entry that contains a temp1_input file, so it works regardless of how the
//   kernel named the card's hwmon instance (hwmon1, hwmon2, ...).
BarWidget {
  id: root
  moduleName: "gileshome.gpu"

  readonly property real pollIntervalMs: 5000

  // ---------------------------------------------------------------------------
  // Card selection
  // ---------------------------------------------------------------------------

  // The per-widget "card" setting, or null when the user left it unset.
  // Backed by a function (not an inline binding) so it reads `settings`
  // lazily — `settings` is injected by the bar host and is not populated
  // during this object's construction, so an inline binding would throw.
  property var cardSetting: cardSettingValue()

  function cardSettingValue() {
    var s = settings
    if (!s) return null
    var v = s["card"]
    return (v === undefined || v === null) ? null : v
  }

  // The resolved card index. Auto-detected when cardSetting is null.
  property int card: -1

  readonly property string deviceDir: card >= 0 ? "/sys/class/drm/card" + card + "/device" : ""

  // Enumerate candidate amdgpu cards and pick the one with the most VRAM.
  property Process detector: Process {
    onExited: {
      var lines = (stdout.text || "").trim().split("\n")
      var best = -1
      var bestVram = -1
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split("\t")
        if (parts.length < 2) continue
        var idx = Number(parts[0])
        var vram = Number(parts[1] || -1)
        if (isNaN(idx)) continue
        // Prefer a card that reports VRAM; otherwise still keep it as a
        // fallback candidate in case none report VRAM at all.
        if (vram >= 0 && vram > bestVram) {
          bestVram = vram
          best = idx
        } else if (best === -1 && vram < 0) {
          best = idx
        }
      }
      root.card = best
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  function autoDetect() {
    // List amdgpu cards as "index<TAB>vram_total_bytes" (vram = -1 when the
    // file is absent). Only cards with a device dir and the amdgpu driver are
    // considered; connector entries (cardN-*) and render nodes are skipped.
    detector.command = ["bash", "-c",
      "for c in /sys/class/drm/card[0-9]*; do " +
      "  b=$(basename \"$c\"); case \"$b\" in card[0-9]*) ;; *) continue ;; esac; " +
      "  d=\"$c/device\"; [ -d \"$d\" ] || continue; " +
      "  dr=$(readlink -f \"$d/driver\" 2>/dev/null); [ \"$(basename \"$dr\" 2>/dev/null)\" = \"amdgpu\" ] || continue; " +
      "  i=${b#card}; " +
      "  v=-1; [ -r \"$d/mem_info_vram_total\" ] && v=$(cat \"$d/mem_info_vram_total\" 2>/dev/null); " +
      "  case \"$v\" in ''|*[!0-9]*) v=-1 ;; esac; " +
      "  printf '%s\\t%s\\n' \"$i\" \"$v\"; " +
      "done"]
    detector.running = true
  }

  // ---------------------------------------------------------------------------
  // Per-metric readers (independent)
  // ---------------------------------------------------------------------------

  // Latest known values, in human units, plus whether each is available.
  property int tempC: 0
  property bool tempOk: false
  property real vramUsedGiB: 0
  property bool vramUsedOk: false
  property real vramTotalGiB: 0
  property bool vramTotalOk: false

  // True once at least one metric has a reading.
  readonly property bool ready: tempOk || vramUsedOk || vramTotalOk

  function toGiB(bytes) {
    return bytes / (1024 * 1024 * 1024)
  }

  // Locate the card's hwmon temp file and cat it. Emits the millidegree value
  // on success; emits nothing (exit 0) when the sensor is absent, so the
  // caller leaves the metric "unavailable" rather than shifting values.
  function readTemp() {
    tempReader.command = ["bash", "-c",
      "t=; " +
      "for d in \"$0/hwmon\"/hwmon*; do " +
      "  [ -f \"$d/temp1_input\" ] && { t=\"$d/temp1_input\"; break; }; " +
      "done; " +
      "if [ -n \"$t\" ] && [ -r \"$t\" ]; then cat -- \"$t\"; fi 2>/dev/null",
      root.deviceDir]
    tempReader.running = true
  }

  function readVramUsed() {
    vramUsedReader.command = ["cat", "--", root.vramUsedPath]
    vramUsedReader.running = true
  }

  function readVramTotal() {
    vramTotalReader.command = ["cat", "--", root.vramTotalPath]
    vramTotalReader.running = true
  }

  readonly property string vramUsedPath: deviceDir + "/mem_info_vram_used"
  readonly property string vramTotalPath: deviceDir + "/mem_info_vram_total"

  property Process tempReader: Process {
    onExited: {
      var v = Number((stdout.text || "").trim())
      if (!isNaN(v) && v > 0) {
        root.tempC = Math.round(v / 1000)
        root.tempOk = true
      }
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  property Process vramUsedReader: Process {
    onExited: {
      var v = Number((stdout.text || "").trim())
      if (!isNaN(v) && v >= 0) {
        root.vramUsedGiB = root.toGiB(v)
        root.vramUsedOk = true
      }
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  property Process vramTotalReader: Process {
    onExited: {
      var v = Number((stdout.text || "").trim())
      if (!isNaN(v) && v >= 0) {
        root.vramTotalGiB = root.toGiB(v)
        root.vramTotalOk = true
      }
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // ---------------------------------------------------------------------------
  // Polling
  // ---------------------------------------------------------------------------

  // Kick off one poll of every metric, but never start a process that is
  // already running (guards against a slow poll overlapping the next timer
  // tick or a card change landing mid-poll).
  function poll() {
    if (root.card < 0) return
    if (!tempReader.running) root.readTemp()
    if (!vramUsedReader.running) root.readVramUsed()
    if (!vramTotalReader.running) root.readVramTotal()
  }

  function resetMetrics() {
    tempC = 0
    tempOk = false
    vramUsedGiB = 0
    vramUsedOk = false
    vramTotalGiB = 0
    vramTotalOk = false
  }

  // Resolve the card, then start polling.
  Component.onCompleted: {
    if (cardSetting === null) {
      autoDetect()
    } else {
      card = Number(cardSetting)
      poll()
    }
  }

  onCardChanged: {
    if (card < 0) return
    resetMetrics()
    poll()
  }

  // Re-detect if the user removes the "card" override at runtime.
  onCardSettingChanged: {
    if (cardSetting === null) {
      autoDetect()
    } else {
      card = Number(cardSetting)
    }
  }

  // sysfs values drift between inotify events, so poll on a fixed cadence.
  Timer {
    interval: root.pollIntervalMs
    running: true
    repeat: true
    onTriggered: root.poll()
  }

  // ---------------------------------------------------------------------------
  // Display
  // ---------------------------------------------------------------------------

  function fmtGiB(gib) {
    return Commons.I18n.formatNumber(gib, 1)
  }

  // Build the label from whatever is available; fall back to an unavailable
  // state when nothing can be read.
  readonly property string labelText: {
    var parts = []
    if (tempOk) parts.push(root.tempC + "°C")
    if (vramUsedOk && vramTotalOk) {
      parts.push(root.fmtGiB(root.vramUsedGiB) + "/" + root.fmtGiB(root.vramTotalGiB) + " GiB")
    } else if (vramTotalOk) {
      parts.push(root.fmtGiB(root.vramTotalGiB) + " GiB")
    } else if (vramUsedOk) {
      parts.push(root.fmtGiB(root.vramUsedGiB) + " GiB")
    }
    return parts.length ? parts.join("  ") : "GPU --"
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
      text: root.labelText
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      color: root.bar.barForeground
    }
  }
}
