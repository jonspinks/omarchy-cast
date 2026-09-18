# omarchy-cast

AirPlay from the Omarchy bar, modelled on the macOS Screen Mirroring menu:
click the AirPlay icon, pick a television, pick how to use it.

Installs as the bar widget `blacksheep.airplay`. It is the front end for
[omarchy-airplay](https://github.com/jonspinks/omarchy-airplay), the Rust
sender that does the actual streaming.

## What it does

The panel has two collapsible sections, **Video** and **Audio**. Opening one
scans the network and lists what it finds; clicking it again rolls it up. Only
one is open at a time, and an open list scrolls rather than growing the panel,
so a house full of speakers cannot push it off the screen.

Pick a television and it offers the three ways to use it:

- **Use as second desktop** — a new workspace that exists only on the TV. Drag
  a window there and it keeps playing while you work elsewhere.
- **Mirror this screen** — everything on the laptop panel.
- **Send one window…** — a single app, chosen from a list of open windows.
  It freezes if its workspace is hidden, so the second desktop is the better
  choice for something you want to watch.

While a session runs, the panel shows the receiver, the mode and (for a second
desktop) the workspace, with a single **Stop**. In the panel, `r` rescans and
`s` stops.

Receivers the sender cannot drive are shown but cannot be selected, with the
reason in the tooltip:

| Receiver | State |
|---|---|
| Samsung Frame (`LS*`) | works — proven end to end |
| Mac | selectable, marked untested |
| Apple TV | not supported — needs FairPlay, which the sender does not implement |
| Speakers (Sonos, HomePod, amps) | not yet — audio is not in the sender |

The **Send audio** switch is present but disabled until audio is ported.

## How it works

Everything goes through `bin/airplay-ctl`, which owns the JSON shapes and the
session lifecycle, so the QML stays simple and the behaviour can be tested
from a shell:

```
bin/airplay-ctl status | discover [timeout] | windows
bin/airplay-ctl start <host> screen|extend|window [target]
bin/airplay-ctl stop | cleanup
```

A session runs as a transient systemd user unit, `airplay-session`, rather
than as a child of the shell. So a shell reload cannot orphan a stream, only
one session can run at a time, and **Stop** is a clean SIGTERM into the
sender's tested teardown. Logs: `journalctl --user -u airplay-session`.

The script looks for `airplay` on `PATH`, then `~/.local/bin/airplay`, then
`~/Work/airplay-rs/target/release/airplay`.

## Requirements

- The `airplay` binary from omarchy-airplay, built with `cargo build --release`.
- `systemd-run`, `hyprctl`, `python3`.

## Notes

- The bar icon is U+F001F (nf-md-airplay). Not the television glyph: the stock
  Display panel uses that one for a single screen.
- Icon changes and anything set at construction only take effect after
  `omarchy restart shell`; plugin hot-reload re-reads the code but does not
  re-create the widget.
