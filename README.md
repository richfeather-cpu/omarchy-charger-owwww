# Owww

Plug in the charger. The laptop says owww. Unplug it, and it keeps that to itself.

Owww is an [Omarchy](https://omarchy.org) shell plugin. While it is enabled, the shell runs a small watcher. The watcher plays a sound on the transition from AC offline to AC online, ignores the first reading so startup stays quiet, and ignores another plug that arrives too soon after one that already played. Unplug does not play anything. Playback goes through PipeWire (`pw-play`, or `paplay` if that fails), so the system volume and mute still apply.

## Install

The plugin runs as unsandboxed code inside `omarchy-shell`. Read it before you turn it on.

```sh
omarchy plugin add https://github.com/richfeather-cpu/omarchy-owww.git
omarchy plugin enable io.github.richfeather-cpu.omarchy-owww
```

`omarchy plugin add` asks whether to enable it now. `--enable` answers yes. The shell writes one entry to `~/.config/omarchy/shell.json` and starts the watcher. Owww does not edit that file itself, and it does not install a systemd unit.

If you previously ran a personal user service for the same idea, stop it or you will hear two sounds:

```sh
systemctl --user disable --now charger-owww.service
```

## Enable and disable

```sh
omarchy plugin enable io.github.richfeather-cpu.omarchy-owww
omarchy plugin disable io.github.richfeather-cpu.omarchy-owww
```

Enable and disable are the shell's own switch. The watcher lives only while the service is loaded, and disabling it stops the watcher and the `udevadm` monitor it started.

Disabling removes this plugin's whole entry from `shell.json`. A custom sound path, volume, or debounce stored on that entry is removed with it. Copy those keys out first if you want them back after the next enable.

## Use your own sound

The bundled clip is the default: `sounds/owww-tts.wav`, about half a second, a synthetic TTS voice generated for this project. Point `sound` at any other file you have the rights to play. WAV is the safe choice.

Enable the plugin first, then add keys to its entry in `~/.config/omarchy/shell.json`. That file is strict JSON. The entry has to stay, because its presence is what "enabled" means:

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "io.github.richfeather-cpu.omarchy-owww",
      "sound": "/home/you/Music/charger.wav",
      "volume": 0.7,
      "debounce": 5,
      "poll": 10
    }
  ]
}
```

| Key | Default | What it does |
| --- | --- | --- |
| `sound` | bundled TTS clip | File to play. `~` expands to your home directory. Empty uses the bundled clip. |
| `volume` | `1.0` | Linear level passed to `pw-play`, from `0` to `2`. `1` is unity. The bundled file is already quiet. `paplay` gets the same level scaled to its 0–65536 range. |
| `debounce` | `5` | Seconds to ignore another plug after one that played. `0` plays on every plug. |
| `poll` | `10` | Seconds between fallback checks when no udev event arrived. Minimum `1`. |

Save the file. The service watches it and restarts the watcher when these keys change. The restart takes a fresh reading and does not play just because settings changed.

If you run `bin/owww` yourself, the same keys can be set with `OWWW_SOUND`, `OWWW_VOLUME`, `OWWW_DEBOUNCE`, and `OWWW_POLL`. Those win over `shell.json`. `OWWW_DRYRUN=1` prints the path instead of playing.

## What it watches

Any supply under `/sys/class/power_supply` counts as the charger when it is online and it is one of:

- type `Mains`
- a USB power type (`USB`, `USB_C`, `USB_PD`, `USB_PD_DRP`, `USB_DCP`, `USB_CDP`, `USB_ACA`, `BrickID`)
- type `Wireless`
- a classic adapter name (`AC`, `AC0`, `ACAD`, `ADP1`, and the other `ADP*` names) even when the kernel leaves `type` unset

Online means any one of those is online. An offline `AC` node does not hide a USB-C supply on another port. Batteries and UPS units are ignored. Nothing here assumes a particular laptop brand.

Plug events come from `udevadm monitor` on the `power_supply` subsystem. A poll covers events missed around suspend and resume. Both run as your user.

## Try it without plugging in

From the installed plugin directory, usually `~/.config/omarchy/plugins/io.github.richfeather-cpu.omarchy-owww`:

```sh
./bin/owww --play      # play the resolved sound once
./bin/owww --status    # show sound, volume, debounce, poll, and AC online
./bin/owww --simulate  # walk a fake plug sequence and print what would play
```

## Troubleshooting

- **Nothing plays.** The shell has to be running. Owww is not a systemd service. Check that the plugin is enabled with `omarchy plugin list`. Then check mute and the output volume, because playback uses the default sink.
- **The shell log.** `qs log -p "$OMARCHY_PATH/shell" --tail 100` shows watcher lines and QML errors. A missing sound file is reported there and the watcher keeps going.
- **No `pw-play`.** `paplay` is the fallback. If neither works, the log says so and the watcher stays up.
- **No `udevadm`.** The watcher polls on the `poll` interval instead of listening for udev events.
- **Two owwws.** An older user unit is probably still enabled. See the install note above.
- **Settings did nothing.** The id must be exactly `io.github.richfeather-cpu.omarchy-owww`, the keys are `sound`, `volume`, `debounce`, and `poll`, and `shell.json` has to be valid JSON. A bad volume or poll value is ignored in favor of the default; the log says which one.
- **Disable forgot your sound path.** That is the shell removing the plugin entry. Put the keys back after you enable it again.

## Remove

```sh
omarchy plugin remove io.github.richfeather-cpu.omarchy-owww
```

Removal disables the plugin first, which stops the watcher, then deletes the checkout. There is no unit, drop-in, or other file to clean up. The only `shell.json` change is the entry the shell itself removes.

## Dependencies

- Omarchy Quattro, for `omarchy plugin` and the shell that hosts the service
- `bash`
- `udevadm` (systemd) for plug events; polling is the fallback
- `pw-play` from PipeWire, or `paplay` from PulseAudio
- `jq` to read settings from `shell.json`, or `python3` if `jq` is not installed
- `awk`, used to check the volume and to scale it for `paplay`

## Tests

The tests are headless. They do not play audio or read the machine's sysfs.

```sh
./tests/test-owww.sh
omarchy plugin validate .
```

## License

MIT. Copyright (c) 2026 Rich Feather. See [LICENSE](LICENSE).
