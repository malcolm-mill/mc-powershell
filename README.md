# mc-powershell

Midnight Commander's two-panel UI over PowerShell's object model.

Not a port of mc, and not another file browser. The panels do not list *files*
-- they list **objects from a PowerShell provider**. The left panel can show
`C:\projects` while the right shows `HKLM:\SOFTWARE`, `Env:\`, `Cert:\`, or
anything a module mounts as a PSDrive, each with columns that make sense for
that provider. That is the whole reason this exists in PowerShell rather than
as a C# rewrite of mc.

**Status: pre-release (0.x), not shippable.** Navigation, the viewer, the
menu bar and the subshell work; file operations do not yet. See
[docs/ROADMAP.md](docs/ROADMAP.md) for what is coming, [CHANGELOG.md](CHANGELOG.md)
for what has landed, and [docs/VERSIONING.md](docs/VERSIONING.md) for what the
numbers mean. `mc -Version` prints the version you are running.

```
┌──────────── C:\projects ────────────┐┌──── HKLM:\SOFTWARE  [Registry] ─────┐
│Name                │  Size│Modify   ││Key                  │ Values│Subkeys│
│..                    UP--            ││/7-Zip               │      2│      0│
│/anki               │   DIR│Jun 24   ││/Adobe               │      0│     11│
│/midnight           │   DIR│Sep 05   ││/Classes             │      0│   7073│
└─────────────────────────────────────┘└─────────────────────────────────────┘
C:\projects>
1Help  2Drive  3View  4Edit  5Copy  6RenMov  7Mkdir  8Delete  9Sort  10Quit
```

## Quick start

**Windows only.** Linux and macOS are frozen, not supported --
see [docs/PLATFORMS.md](docs/PLATFORMS.md).

Requires PowerShell 7.2+ and the .NET SDK (8 or later) to build the native layer.

```powershell
./build.ps1
./mc.ps1

# or start each panel somewhere specific
./mc.ps1 -Left C:\projects -Right HKLM:\SOFTWARE
```

### Run it from anywhere

```powershell
./tools/Install-McCommand.ps1
```

Adds an `mc` function to your PowerShell profile pointing at this checkout, so
`mc` works from any prompt and opens the panels in the directory you are in.
Arguments forward, so `mc -Left C:\projects -Right Env:` behaves the same.

A profile function rather than a PATH entry: nothing else gets shadowed,
named arguments forward cleanly, and it is one delimited block that is easy to
read and to remove. Re-running the script rewrites the block rather than adding
another; `-Uninstall` takes it out. Move the checkout and run it again, because
the path it writes is absolute.

Both test suites run headlessly -- no terminal needed, because the panel is a
pure state machine and the renderer can paint to a text buffer:

```powershell
./tests/Smoke.ps1        # render a frame and print it as text
./tests/KeySequence.ps1  # drive a scripted key sequence, assert on state
./tests/Guard.ps1        # safety modes and the command-line screen
./tests/Interface.ps1    # layout, menu hit boxes, mouse routing, viewer
./tests/Keys.ps1         # raw key event -> canonical name -> app response
./tests/Lint.ps1         # parse, Split-Path misuse, export drift, CI wiring
```

## Safety: read-only by default

**mc-powershell starts read-only every time, and the mode is never persisted.**
Nothing can be created, changed or deleted -- files, registry keys or
environment variables -- until you deliberately say otherwise. The current mode
is always visible as a badge at the left of the command line.

| Command | Effect |
|---|---|
| `mc.ps1.ro` | Return to read-only (the default) |
| `mc.ps1.rw` | Ask to enable read-write; the confirmation defaults to **No** |
| `mc.ps1.mode` | Report the current mode |

mc's own operations pass through a single choke point, `Assert-McWritable`,
which makes them airtight. The command line runs arbitrary PowerShell, so it
gets an AST screen plus `$WhatIfPreference` instead -- strong against mistakes,
but explicitly **not** a sandbox. [docs/SAFETY.md](docs/SAFETY.md) states
exactly what is and is not caught.

## Keys

| Key | Action |
|---|---|
| Arrows, PgUp/PgDn, Home/End | Move the cursor |
| Enter | Descend into the highlighted container |
| Ctrl+PgUp | Go up one level (mc's binding) |
| Backspace | Delete a command-line character (never navigates, as in mc) |
| Tab | Switch panel |
| Insert | Mark / unmark, advance |
| F2 | **Change drive or provider** -- pick any PSDrive |
| F9 | Menu bar (Left / File / Command / Options / Right) |
| F3 | View file in the built-in viewer |
| F5-F8 | Copy / move / mkdir / delete -- refused in read-only mode, not implemented yet in read-write (M3) |
| F10 | Quit |
| Ctrl+R | Reload panel |
| Ctrl+U | Swap panels |
| Alt+. | Toggle hidden files |
| Ctrl+O | Drop into a full-screen shell in the active panel's directory; Ctrl+O again (or `exit`) returns, and the panel follows any `cd` |
| Ctrl+Up / Ctrl+Down | Grow / shrink the output pane under the panels |
| *typing* | Goes to the command line; Enter runs it in the active panel's location |

## When a key does not work

```powershell
./tools/keytest.ps1
```

Shows what the input layer actually receives: the canonical name, the raw
Windows virtual key code and control state, and whether the app has anything
bound to it. mc has "Learn keys" for the same reason -- the first question is
always whether the key even arrived.

## Mouse

Click the function key bar instead of pressing F1-F10 -- useful when the OS or
terminal has already claimed those keys. Clicking a menu title opens it, a
click in a panel focuses that panel and moves the cursor, clicking the
highlighted row again descends into it, and the wheel scrolls whichever panel
is under the pointer.

The mouse needs `ReadConsoleInput`, because `Console.ReadKey` discards mouse
events. If that setup is refused -- input redirected, an unusual host -- the app
falls back to key-only input rather than failing. Options -> Mouse support
reports which you got.

## Viewer

F3 opens the built-in viewer. It works out the encoding from the bytes -- BOM
first, then UTF-8, falling back to Latin-1 so odd bytes show as the wrong glyph
rather than being destroyed -- and refuses to spew a binary file at you.

| Key | |
|---|---|
| Arrows / PgUp / PgDn / Home / End | Move |
| Left / Right | Scroll sideways when not wrapping |
| F2 | Wrap on/off |
| F4 | Line numbers on/off |
| F5 | Go to line |
| F7 | Search; `n` and `N` for next and previous |
| F3, F10, Esc, `q` | Close |

Markdown rendering and a hex mode come later; this is the plumbing they sit on.

## The shell

Two ways to work with a shell, following mc:

**Ctrl+O** hands the whole terminal to a shell starting in the active panel's
directory. Press Ctrl+O again to come back, as in mc (`exit` also works), and
the panel follows you if you `cd` somewhere. Commands run in *this* PowerShell session, so variables, modules and
location persist across trips in and out -- mc needs a pty subshell to achieve
what we get for free.

**Ctrl+Up** opens an output pane under the panels (mc's "Output lines" setting).
With it open, commands typed on the command line run *in place* and their output
appears in the pane -- no screen switch at all. Ctrl+Down shrinks it again. mc
can only do this on a Linux virtual console, because it reads the physical
console buffer; we own the renderer, so it works everywhere.

## How it is built

A hybrid, on purpose. C# does the work that script is bad at; everything else
is PowerShell so features stay editable without a rebuild.

```
src/Mc.Native/       C#  screen buffer, ANSI diff, key decoding, fast enumeration
src/Mc.PowerShell/   PS  sources, panel state, layout, rendering, keymap, dialogs
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the layering and why it is
split where it is.

## Adding a panel source

A source is a hashtable of scriptblocks. This is the extension point -- a
plugin is just a PowerShell function, no rebuild required:

```powershell
Register-McPanelSource -Source @{
    Name        = 'MyThing'
    Priority    = 50
    Test        = { param($Location) $Location -like 'thing:*' }
    GetChildren = { param($Location, $ShowHidden) <# -> Mc.Native.PanelEntry[] #> }
    Descend     = { param($Location, $Entry) "thing:$($Entry.Name)" }
    Parent      = { param($Location) <# -> parent or $null #> }
    Title       = { param($Location) "Thing: $Location" }
    Columns     = { param($Location) @(
        @{ Header = 'Name'; Width = -1; Align = 'Left'; Get = { param($e) $e.Name } }
    ) }
}
```

## What is next

[TODO.txt](TODO.txt) holds the next few concrete jobs;
[docs/ROADMAP.md](docs/ROADMAP.md) holds the milestones.

## Repository layout

| Branch | Contents |
|---|---|
| `main` | This project. PowerShell + C#. |
| `reference` | Unmodified GNU Midnight Commander source, kept as the requirements spec. |

`reference` is never merged into `main`. It is there to be read: when a
behaviour question comes up, the answer is in the C. See
[docs/REFERENCE-BRANCH.md](docs/REFERENCE-BRANCH.md) for the map.

## Licence

GPL-3.0-or-later, inherited from GNU Midnight Commander. See [COPYING](COPYING).
