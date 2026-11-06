# Omarchy GPU Monitor

A small [Omarchy](https://omarchy.org/) shell bar widget that shows a GPU's
temperature and VRAM usage, read straight from `sysfs`. It's meant for the
discrete GPU (dGPU) on a hybrid iGPU + dGPU laptop, e.g. an AMD Radeon RX 9050
/ 9060 XT.

```
49°C  15.8/15.9 GiB
```

## What it shows

- **Temperature** — from the card's hwmon `temp1_input` (millidegrees → °C).
- **VRAM** — `mem_info_vram_used` / `mem_info_vram_total`, shown in GiB.

The card's hwmon instance is discovered automatically (it scans
`/sys/class/drm/card<N>/device/hwmon/` for the entry that has a
`temp1_input`), so it works whether the kernel named it `hwmon1`, `hwmon2`,
etc.

Values are polled every 5 seconds with a single short-lived `cat` over the
three files — no extra daemons, no `amdgpu` userspace tools required.

## Install

The plugin lives in your user plugin directory:

```sh
mkdir -p ~/.config/omarchy/plugins
git clone <this-repo> ~/.config/omarchy/plugins/gileshome.gpu
```

Then add it to the bar and enable it:

```sh
omarchy bar put gileshome.gpu right
omarchy plugin enable gileshome.gpu
omarchy restart shell
```

(If the clone was created in a different directory name, the plugin id is
still `gileshome.gpu` — it comes from `manifest.json`, not the folder name.)

## Configuration

The card index defaults to **`1`** (the dGPU on most hybrid laptops). To point
it at a different card, add a `"card"` key to this widget's entry in
`~/.config/omarchy/shell.json` under `bar.layout` (the section you added it to):

```json
"right": [
  { "id": "gileshome.gpu", "card": 0 }
]
```

Then restart the shell: `omarchy restart shell`. The widget re-reads the card
on change and resets until it has fresh values.

To find your card index, list the DRM cards and check which is the dGPU:

```sh
ls /sys/class/drm/
# card0  card1  card2  card3-DP-1  ...
```

On a typical laptop `card0` is the iGPU and `card1` is the dGPU.

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
