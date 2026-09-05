# mc-powershell

Midnight Commander's two-panel UI over PowerShell's object model.

Not a port of mc, and not another file browser. The panels do not list *files*
-- they list **objects from a PowerShell provider**. The left panel can show
`C:\projects` while the right shows `HKLM:\SOFTWARE`, `Env:\`, `Cert:\`, or
anything a module mounts as a PSDrive, each with columns that make sense for
that provider. That is the whole reason this exists in PowerShell rather than
as a C# rewrite of mc.

**Status: 0.1 -- walking skeleton.** Navigation works, file operations do not
yet. See [docs/ROADMAP.md](docs/ROADMAP.md).

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

Requires PowerShell 7.2+ and the .NET SDK (8 or later) to build the native layer.

```powershell
./build.ps1
./mc.ps1

# or start each panel somewhere specific
./mc.ps1 -Left C:\projects -Right HKLM:\SOFTWARE
```

Both test suites run headlessly -- no terminal needed, because the panel is a
pure state machine and the renderer can paint to a text buffer:

```powershell
./tests/Smoke.ps1        # render a frame and print it as text
./tests/KeySequence.ps1  # drive a scripted key sequence, assert on state
./tests/Guard.ps1        # safety modes and the command-line screen
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

## Keys in 0.1

| Key | Action |
|---|---|
| Arrows, PgUp/PgDn, Home/End | Move the cursor |
| Enter | Descend into the highlighted container |
| Backspace | Go up one level |
| Tab | Switch panel |
| Insert | Mark / unmark, advance |
| F2 | **Change drive or provider** -- pick any PSDrive |
| F3 | View file |
| F9 | Sort order |
| F5-F8 | Copy / move / mkdir / delete -- refused in read-only mode, not implemented yet in read-write (M3) |
| F10 | Quit |
| Ctrl+R | Reload panel |
| Ctrl+U | Swap panels |
| Alt+. | Toggle hidden files |
| Ctrl+O | Drop into a full-screen shell in the active panel's directory; `exit` returns, and the panel follows any `cd` |
| Ctrl+Up / Ctrl+Down | Grow / shrink the output pane under the panels |
| *typing* | Goes to the command line; Enter runs it in the active panel's location |

## The shell

Two ways to work with a shell, following mc:

**Ctrl+O** hands the whole terminal to a shell starting in the active panel's
directory. Type `exit` to come back, and the panel follows you if you `cd`
somewhere. Commands run in *this* PowerShell session, so variables, modules and
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
