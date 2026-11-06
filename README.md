# Omarchy GPU Monitor

A small [Omarchy](https://omarchy.org/) shell bar widget that shows an AMD
GPU's temperature and VRAM usage, read straight from `sysfs`. It's aimed at
the discrete GPU (dGPU) on a hybrid iGPU + dGPU laptop, e.g. an AMD Radeon RX
9050 / 9060 XT, but works with any `amdgpu` card.

```
51°C  15.4/16.0 GiB
```

## What it shows

- **Temperature** — from the card's hwmon `temp1_input` (millidegrees → °C).
- **VRAM** — `mem_info_vram_used` / `mem_info_vram_total`, shown in GiB.

Each value is read **independently**, so a missing or unreadable sensor or
file never shifts the other values or hides a reading that is still available.
If nothing can be read at all, the widget shows an `GPU --` placeholder (and
hides itself once it has at least one reading).

The card's hwmon instance is discovered automatically (it scans
`/sys/class/drm/card<N>/device/hwmon/` for the entry that has a
`temp1_input`), so it works whether the kernel named it `hwmon1`, `hwmon2`,
etc.

Values are polled every 5 seconds with short-lived `cat` processes — no extra
daemons, no `amdgpu` userspace tools required. A poll never starts a process
that is already running, so slow reads can't stack up.

## Install

Clone the repo into your user plugin directory:

```sh
mkdir -p ~/.config/omarchy/plugins
git clone <REPO_URL> ~/.config/omarchy/plugins/gileshome.gpu
```

`<REPO_URL>` is the GitHub URL of this repository (fill in once published).

Then add it to the bar and make sure it's enabled:

```sh
omarchy bar put gileshome.gpu right
omarchy plugin enable gileshome.gpu
omarchy restart shell
```

Notes:

- `omarchy bar put gileshome.gpu right` adds the widget to the `right` section
  of `bar.layout` in `~/.config/omarchy/shell.json` and enables it. Pick a
  different section (`left`, `centerBegin`, `centerEnd`, …) if you want.
- The plugin id is `gileshome.gpu`, taken from `manifest.json` — it does not
  depend on the folder name, so the clone directory name doesn't matter.
- `omarchy restart shell` is required after cloning or editing the QML (see
  "Development notes" below).

## Configuration

### Which GPU

By default the widget **auto-detects** the GPU to monitor: it enumerates
`/sys/class/drm/cardN`, keeps the ones driven by `amdgpu`, and picks the one
with the most reported VRAM. On a hybrid laptop that's the dGPU (a 16 GiB dGPU
vs a 512 MiB iGPU); on a dGPU-only desktop it's just the GPU. Auto-detection
runs once at shell startup.

To pin a specific card instead, add a `"card"` key to this widget's entry in
`~/.config/omarchy/shell.json` under the `bar.layout` section you added it to:

```json
"right": [
  { "id": "gileshome.gpu", "card": 1 }
]
```

Then run `omarchy restart shell`. The widget re-reads the card on change and
resets until it has fresh values.

To find your card index, list the DRM cards and check which is the dGPU:

```sh
ls /sys/class/drm/
# card0  card1  card0-DP-2  card1-HDMI-A-1  ...
```

On a typical hybrid laptop `card0` is the iGPU and `card1` is the dGPU.

### Poll interval

The poll cadence is `pollIntervalMs` (default `5000`) in `BarWidget.qml`.

## Troubleshooting

- **Widget is empty / not showing.** The GPU isn't readable. Confirm the card
  index: `ls /sys/class/drm/` and check
  `cat /sys/class/drm/card<N>/device/mem_info_vram_total`. If auto-detection
  picked the wrong card, set `"card"` explicitly (above).
- **No temperature but VRAM shows (or vice-versa).** That's expected — the
  metrics are independent. The card may not expose a `temp1_input` hwmon
  sensor, or the VRAM files may be missing.
- **Values look wrong.** Check the raw files:
  `cat /sys/class/drm/card<N>/device/mem_info_vram_used`
  `cat /sys/class/drm/card<N>/device/mem_info_vram_total`
  and the hwmon temp under
  `/sys/class/drm/card<N>/device/hwmon/hwmon*/temp1_input`.
- **Edited the QML but nothing changed.** Hot-reload doesn't pick up edited QML
  file content; run `omarchy restart shell` (see below).
- **Check for load errors:**
  `journalctl --user -t omarchy-shell --no-pager --since "1 minute ago" | grep -i gileshome`

## Removal

There is no `omarchy bar remove` subcommand — to take the widget off the bar,
delete its entry from `bar.layout` in `~/.config/omarchy/shell.json` (the
`{ "id": "gileshome.gpu" }` object in whichever section you added it to). The
bar hot-reloads on save, so no restart is needed for that step.

Then remove the plugin itself:

```sh
omarchy plugin remove gileshome.gpu   # uninstalls the plugin (and its bar entry)
```

If you installed it by cloning (rather than `omarchy plugin add`), also delete
the clone directory:

```sh
rm -rf ~/.config/omarchy/plugins/gileshome.gpu
```

## Development notes

Two Omarchy/Quickshell quirks shaped this plugin:

- **`FileView` is unusable in user plugins.** `Quickshell.Io`'s `FileView.qml`
  resolves through the shell's config-folder import path, which blackholes
  paths outside the config folder, so a plugin under
  `~/.config/omarchy/plugins/` always gets `FileView is not a type`. This
  plugin therefore uses the bare `Process` / `StdioCollector` types (both
  resolve fine from anywhere) and polls the files with `cat`.
- **Hot-reload doesn't pick up edited QML file content.** The shell serves Qt's
  cached compiled component for the file URL, so after editing a plugin's QML
  you must run `omarchy restart shell` (a plain `rescanPlugins` only re-runs
  the manifest scan, not the component rebuild).

## License

[MIT](LICENSE)
