# sysdeck

[![SEGV 
LICENSE](https://img.shields.io/static/v1?label=SEGV%20LICENSE&message=1.1&labelColor=0060A8&color=ffffff)](https://xn--gckvb8fzb.com/segv/)

![sysdeck](screenshot.png)

_sysdeck_ is a command center for Linux and the BSDs. It is the less bloated
Linux/BSD equivalent to _Raycast_ on macOS.

[<img src="https://xn--gckvb8fzb.com/images/chatroom.png" width="275">](https://xn--gckvb8fzb.com/contact/)

_sysdeck_ is supposed to be bound to a hotkey, which will activate it, allowing
you to type in something. It then shows what matches across various areas,
including:

- Applications
- Command line executables
- Files and folders
- Clipboard history
- Sway windows
- Arithmetic operations
- etc.

_sysdeck_ keeps track of the things you search for and use, and optimizes its
suggestions based on that data.

It can run applications, opens executables it in your favorite terminal, show
the processes that are running, allowing you to focus them, and it shows manual
pages for programs that have them.

_sysdeck_ also replaces `dmenu` with its integrated `--dmenu` mode:

```sh
ls | sysdeck --dmenu | xargs -I {} echo "I selected {}"
```

## Features

_sysdeck_ separates between sources and extensions. A source returns entries for
what you type, an extension however gives more information about the selected
entry. Each one can be turned off in the configuration, usually via their
`[sources.<name>]` or `[extensions.<name>]` settings.

### Sources

| Source       | Description                                                                                 |
| ------------ | ------------------------------------------------------------------------------------------- |
| `apps`       | Installed applications, launched with optional arguments, with their actions under _Alt_    |
| `bins`       | Command line executables in `$PATH`, run in your terminal with optional arguments           |
| `bookmarks`  | Bookmarks from Markdown files and from Chromium- and Firefox-based browsers                 |
| `clipboard`  | Clipboard history recorded through `wl-paste`, copied back on _Return_                      |
| `disk`       | Files and folders in the configured locations, opened with their default application        |
| `inca`       | CardDAV contacts that Inca synchronized, with their details to copy under _Alt_             |
| `llm`        | Questions to a configured Gemini, OpenAI or Anthropic model, or an OpenAI-compatible server |
| `mpris`      | Media commands for running players, such as _Play/Pause_, _Next_ and _What's playing?_      |
| `nm`         | NetworkManager devices and connections, to connect or disconnect them                       |
| `podman`     | Podman containers, started or stopped on _Return_, with their details to copy under _Alt_   |
| `processes`  | Process IDs of running programs on their entries, to focus their (Sway) window or end them  |
| `screenshot` | Screenshots of a region, a window or a whole screen, saved and optionally copied            |
| `snippets`   | Your own text snippets and every emoji, copied on _Return_                                  |
| `ssh`        | Hosts from `~/.ssh/config`                                                                  |
| `sway`       | List open Sway windows, focus on _Return_                                                   |
| `websearch`  | Configured search providers, searched for what you type after _Tab_                         |
| `whats`      | Calculations and unit and currency conversions of what you type                             |

### Extensions

| Extension | Description                                                          |
| --------- | -------------------------------------------------------------------- |
| `man`     | Manual page of the selected executable, with a tab for each section  |
| `preview` | Preview of the selected entry: images with their EXIF data, and text |

## Installation

_sysdeck_ is built from source. It needs Zig 0.17.1 or newer and the following
development files:

| System  | Packages                                                                                                                 |
| ------- | ------------------------------------------------------------------------------------------------------------------------ |
| Fedora  | `gtk4-devel glib2-devel sqlite-devel libgexiv2-devel cairo-devel wayland-devel gtk4-layer-shell-devel`                   |
| Debian  | `libgtk-4-dev libglib2.0-dev libsqlite3-dev libgexiv2-dev libcairo2-dev libwayland-dev libgtk4-layer-shell-dev`          |
| Arch    | `gtk4 glib2 sqlite libgexiv2 cairo wayland gtk4-layer-shell`                                                             |
| Alpine  | `gtk4.0-dev glib-dev sqlite-dev gexiv2-dev cairo-dev wayland-dev gtk4-layer-shell-dev`                                   |
| Gentoo  | `gui-libs/gtk:4 dev-libs/glib dev-db/sqlite media-libs/gexiv2 x11-libs/cairo dev-libs/wayland gui-libs/gtk4-layer-shell` |
| Void    | `gtk4-devel glib-devel sqlite-devel gexiv2-devel cairo-devel wayland-devel gtk4-layer-shell-devel`                       |
| FreeBSD | `gtk4 glib sqlite3 gexiv2 cairo wayland gtk4-layer-shell`                                                                |
| OpenBSD | `gtk+4 glib2 sqlite3 gexiv2 cairo wayland gtk4-layer-shell`                                                              |
| NetBSD  | `gtk4 glib2 sqlite3 gexiv2 cairo wayland gtk4-layer-shell`                                                               |

```sh
zig build -Doptimize=fast --prefix ~/.local
```

That writes `~/.local/bin/sysdeck`. You can set `--prefix /usr/local` for a
system wide install instead.

## Configuration

First, bind _sysdeck_ to a key in your window manager. On Sway for example like
this:

```
bindsym $mod+space exec sysdeck
```

**Note:** _sysdeck_ does not position its own window (because it can't). If your
compositor puts it somewhere you don't like, tell the compositor where to put
it:

```
for_window [app_id = "sysdeck"] {
  floating enable
  move up 300 px
}
```

The window can be made translucent if you would want it to be using the
`[window]` option `opacity` (values from `0.1` to `1.0`). Compositors that
implement the `ext-background-effect-v1` protocol, such as KWin 6.7, Hyprland
0.56, niri 26.04, Mutter 51 and COSMIC, additionally blur the background behind
it as well because it seems like glass-like aesthetics are big these days. For
example Sway, however, has no blur, but it can be simulated using
`static_blur = true` under `[window]`, which makes _sysdeck_ draw a blurred
picture of the screen behind the window instead. Obviously if the background
behind _sysdeck_ is something that changes (e.g. video) this workaround won't
work, but for your average `r/unixporn` post it should be fairly sufficient.

## Usage

Type to search and use the arrow keys to move through the list. Press _Return_
to accept the selected entry or _Escape_ to close the popup. The popup also
closes when it loses focus. The footer names the mode, what _Return_ does with
the selected entry and, if the entry has a context menu, the key that opens it.

Entries that have a manual page show it underneath. Press _Alt_ to show an
entry's context menu (if it has one), press the number of the right side in the
context menu to run the specific command.

Switch through the manual pages with the function keys, so _Alt+F1_ shows
`man 1`, _Alt+F5_ shows `man 5`, if those exist (visible via the tabs). Both
shortcuts are defaults you can change, see `[keys]` below.

Each mode can be entered using a dedicated shortcut, or started directly with
its flag. _Ctrl+F_ goes back to the general search:

| Key      | Flag                  | Mode       | Description                                           |
| -------- | --------------------- | ---------- | ----------------------------------------------------- |
| _Ctrl+F_ |                       | Search     | Applications, executables, bookmarks and disk entries |
| _Ctrl+T_ | `--sway`              | Windows    | Open Sway windows, to focus one                       |
| _Ctrl+H_ | `--clipboard-history` | History    | Clipboard history, newest first                       |
| _Ctrl+D_ | `--disk`              | Disk       | Configured disk locations                             |
| _Ctrl+K_ | `--nm`                | Network    | NetworkManager devices and connections                |
| _Ctrl+L_ | `--llm`               | LLM        | Ask a configured LLM, again for the next provider     |
| _Ctrl+W_ | `--whats`             | Whats      | Calculate and convert what you type                   |
| _Ctrl+P_ | `--phonebook`         | Look up    | Contacts that Inca synchronized                       |
| _Ctrl+0_ | `--containers`        | Containers | Podman containers, to start or stop them              |

**Note:** _Ctrl+T_ does nothing without Sway, _Ctrl+K_ does nothing without
NetworkManager, _Ctrl+P_ lists nothing without Inca, and _Ctrl+0_ lists nothing
without Podman.

### Clipboard

_sysdeck_ replaces programs like `cliphist`. Add one line to your
`~/.config/sway/config` and everything you copy is recorded:

```
exec wl-paste --watch sysdeck --clipboard-capture > /dev/null
```

Then press _Ctrl+H_ for the last 100 entries and type to narrow them down.
_Return_ puts the entry back on the clipboard and closes the popup.

Text, images, audio, video and documents are all recorded, each with the icon of
its kind and the text or the type as its title. An entry you copy again is not
duplicated. Instead, _sysdeck_ finds the one it already has, increments its
usage counter and moves it to the top.

`sysdeck --clipboard-clear` empties the history and exits. It is safe to run at
any time.

You need `wl-clipboard` installed, which is where both `wl-paste` and `wl-copy`
come from. A copy that is marked as sensitive (e.g. by a password manager) is
never recorded. `wl-copy --clear` deletes the newest entry, so even a mistakenly
copied password can be taken back out.

Starting _sysdeck_ with `--clipboard-history` opens it on the history directly,
which is what you would bind a second hotkey to, e.g.:

```
bindsym $mod+v exec sysdeck --clipboard-history
```

### Preview

Any entry you have selected is previewed under the list if the entry type has a
preview. For example image in the clipboard or in the file browser is displayed
with a line above it naming the type, the pixel dimensions and the size, along
with whatever the camera recorded in the EXIF block (e.g. the body and lens, the
exposure, the aperture and the ISO). When a photograph records where it was
taken, the coordinates also appear on that line as a link to OpenStreetMap.

Copied text is shown in full in a read-only box you can scroll, so you can drag
the mouse across it and select the part you actually wanted.

For audio, video and documents there is no preview yet.

The pane is configured in `[extensions.preview]`, where you can turn it off or
change how tall it is allowed to get.

### dmenu

Use the dmenu mode with the `--dmenu` flag:

```sh
sysdeck --dmenu < list.txt
```

_sysdeck_ exits with `0` when you picked something and with `1` when you pressed
_Escape_.

### Options

| Option                | Description                                   |
| --------------------- | --------------------------------------------- |
| `--dmenu`             | Read the list from standard input             |
| `--clipboard-capture` | Record standard input in the history and exit |
| `--clipboard-clear`   | Remove every entry from the history and exit  |
| `--recommendations`   | Show what you pick most often on an empty box |
| `-p`, `--prompt`      | Set the placeholder shown in the text box     |
| `-l`, `--lines`       | Show at most this many rows                   |
| `-h`, `--help`        | Print the help and exit                       |
| `-v`, `--version`     | Print the version and exit                    |

`--clipboard-capture` is meant for `wl-paste --watch` and doesn't display
anything at all. It's not supposed to be run by the user.

## Configuration

Configuration is optional and read from `$XDG_CONFIG_HOME/sysdeck/config.toml`,
or from `$HOME/.config/sysdeck/config.toml` when `XDG_CONFIG_HOME` is unset. A
documented example can be found in [`config.example.toml`](config.example.toml).

## Database

The main database in which _sysdeck_ stores indexes is in
`$XDG_DATA_HOME/sysdeck/sysdeck.db`. An index is rebuilt in the background when
it gets older than `max_age_minutes`, and while that happens queries go against
the (maybe) outdated index.

The clipboard history is a second database in the same directory,
`clipboard.db`. It is kept apart because an index can be rebuilt from the system
at any time, but the clipboard cannot. Besides, in case you'd want to
store/backup your clipboard somewhere (ideally in an encrypted format) you can.

Both databases are opened in WAL mode, so the popup reading the history and
`--clipboard-capture` writing to it do not wait for each other.

## License

Copyright © 2026 [マリウス](https://xn--gckvb8fzb.com)

_sysdeck_ is released under Version 1.1 of the
[SEGV License](https://xn--gckvb8fzb.com/segv/), whose full text is included in
the [LICENSE](LICENSE) file. Go read it, there will be a test on it on Monday.
