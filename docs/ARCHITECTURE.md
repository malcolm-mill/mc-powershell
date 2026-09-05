# Architecture

## The split

```
+---------------------------------------------------------------+
|  Mc.PowerShell  (script -- edit and reload, no rebuild)        |
|                                                               |
|  Sources.ps1   panel sources: FileSystem, PSProvider, plugins  |
|  Panel.ps1     panel state machine -- pure, no I/O             |
|  Render.ps1    state -> character grid                         |
|  App.ps1       keymap, dialogs, main loop                      |
+---------------------------------------------------------------+
                              |
+---------------------------------------------------------------+
|  Mc.Native  (C# -- the hot paths)                              |
|                                                               |
|  Screen.cs      double-buffered cell grid, ANSI diff emit      |
|  Terminal.cs    alt screen, VT enable, UTF-8, guaranteed restore|
|  Keys.cs        host key events -> canonical names             |
|  PanelEntry.cs  the row type + fast filesystem enumeration     |
+---------------------------------------------------------------+
```

The line between them is not "C# is faster so put more there". It is:

- **C# owns anything that runs per cell or per directory entry.** Painting a
  100x30 screen is 3000 cell writes; enumerating a large directory is tens of
  thousands of stat calls. Script loses badly at both.
- **PowerShell owns anything a user might want to change.** Column definitions,
  sources, keymap, dialogs, file operations. A plugin is a function, not a
  rebuild.

## Why the state machine is pure

`Panel.ps1` never draws and never reads a key. It exposes operations
(`Move-McPanelCursor`, `Invoke-McPanelEnter`, `Set-McPanelSort`) that take state
and mutate state. Two consequences:

1. Panel behaviour is testable with Pester without a terminal -- feed
   operations, assert on `$panel.Index`, `$panel.Top`, `$panel.Location`.
2. Rendering is testable by **golden frames**: `Screen.Snapshot()` returns the
   back buffer as plain text, so a test renders a fixed state and diffs against
   a checked-in fixture. `tests/Smoke.ps1` is the seed of that harness.

Neither test needs a TTY, which is what makes CI on three platforms possible.

## The source contract

A panel knows nothing about files. It holds a *location* (a string) and asks a
*source* to turn it into rows. `Get-McPanelSource` picks the highest-priority
source whose `Test` accepts the location.

Two ship today:

| Source | Priority | Handles |
|---|---|---|
| `FileSystem` | 100 | `C:\...`, `\unc\...`, `/...` -- enumerated in C# |
| `PSProvider` | 10 | anything `Test-Path` accepts: `Env:`, `HKLM:`, `Cert:`, `Function:`, module drives |

`FileSystem` outranks `PSProvider` for real paths purely for speed; the
PSProvider source would handle them correctly, just slower.

Columns come from the source, per location. That is why `Env:` shows
Name/Value, `HKLM:` shows Key/Values/Subkeys, and `C:\` shows
Name/Size/Modify time -- with no special-casing anywhere in the renderer.

## Rendering

`Screen` keeps two buffers. All drawing goes to the back buffer; `Flush()` walks
it, compares against the front buffer, and emits **one** string containing only
the cells that changed, with cursor moves and SGR changes coalesced. Nothing
else in the codebase writes to stdout.

Autowrap is disabled (`ESC[?7l`) so writing the bottom-right cell does not
scroll the screen -- a classic full-screen TUI bug.

## Known performance ceiling

Measured on a 110x26 frame, PowerShell 7.6 / .NET 10:

- first frame: ~250 ms (JIT + module load)
- steady state: ~15 ms/frame

15 ms is fine for a keyboard-driven app that only repaints on a keystroke, but
it scales with cell count -- a 200x50 terminal would be ~50 ms and start to feel
sticky. The cost is the per-cell interop from script, not the diff.

**The fix, when it is needed:** move the row-painting loop into C#. Pass the
column widths and an array of pre-computed strings, and let `Screen` do the
`WriteFixed` calls in a single call. Deliberately not done yet -- see
[ROADMAP.md](ROADMAP.md) M2.

## Terminal restore

`Terminal.Init()` and `Terminal.Shutdown()` are idempotent and `Shutdown()` runs
in a `finally` block in `Start-Mc`. A crash must never leave the user in the
alternate buffer with a hidden cursor. `Invoke-McShellCommand` uses the same
pair to drop to the shell and come back.
