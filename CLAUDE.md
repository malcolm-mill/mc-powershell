# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

mc-powershell: Midnight Commander's two-panel UI over PowerShell's object model. Panels list objects from any PSProvider (`C:\`, `HKLM:`, `Env:`, `Cert:`), not just files. Pre-release 0.x, Windows only, GPL-3.0-or-later. Read `README.md` and `docs/ARCHITECTURE.md` first; `docs/COMPAT.md` is the behaviour spec. The same files are published as a GitHub Pages site from the root of `main` (`_config.yml`), with README as the front page, so keep links between them relative.

## TODO.txt

`TODO.txt` is the owner's list: one numbered line per open feature or fix, terse. It is there for your information. **Do not edit it unless asked**, and do not keep a notes or scratch file of your own in the repository. Diagnosis and reasoning belong in the conversation and in commit messages.

## Branches

- `main` is this project. PRs target `main`, not `master`.
- `master` and `reference` are the unmodified upstream GNU mc C source. Never merge them into `main` and never copy code out. They exist to be read when a behaviour question comes up: `git show reference:src/filemanager/panel.c`, `git grep -n 'pattern' reference -- src/`. `docs/REFERENCE-BRANCH.md` maps questions to files; mc's default keys are in `misc/mc.default.keymap` on that branch.

## Commands

```powershell
./build.ps1                 # dotnet build of src/Mc.Native, then stages the DLL into src/Mc.PowerShell
./mc.ps1                    # run; -Left / -Right set panel paths, -Version prints the version
./tests/Lint.ps1            # parse every .ps1, Split-Path misuse, export drift, version/changelog, CI wiring
./tests/Smoke.ps1           # render one frame headlessly, print it, time steady-state
./tests/KeySequence.ps1     # scripted key dispatch, asserts on panel state
./tests/Keys.ps1            # raw Windows key event -> canonical name -> handler
./tests/Guard.ps1           # read-only mode, Assert-McWritable, command screen
./tests/Interface.ps1       # layout, menu hit boxes, mouse routing, viewer file loading
./tools/keytest.ps1         # interactive: shows what the input layer receives for a key
```

There is no Pester and no test runner. Each suite is a standalone script with an inline `Assert-That`; run the one suite you care about, and CI (`.github/workflows/ci.yml`) runs all six after the build. Lint fails if a new `tests/*.ps1` is not listed in `ci.yml`.

**After changing any C# you must start a new PowerShell session.** .NET cannot unload an assembly, so a session that has already imported the module keeps the old build; the loader detects this and throws rather than running stale code. The loader picks the newest of the staged DLL and the `bin/Release` / `bin/Debug` outputs and loads it from a shadow copy in `%TEMP%\mc-powershell-native`, so `dotnet build` still works while another session holds the assembly.

Script changes need no rebuild: `Import-Module ./src/Mc.PowerShell/Mc.psd1 -Force`.

## Architecture

**The split is by responsibility, not speed.** C# (`src/Mc.Native`, netstandard2.0) owns anything that runs per cell or per directory entry: `Screen.cs` (double-buffered cell grid, `Flush()` emits one ANSI string of changed cells only, nothing else writes to stdout), `Terminal.cs` (alt screen, VT, idempotent `Init`/`Shutdown` in a `finally`), `Keys.cs`/`Input.cs` (`ReadConsoleInput` with a `Console.ReadKey` fallback; keys become canonical names like `C-pgup`, `M-.`, `f3`), `PanelEntry.cs` (row type, fast enumeration, sort). PowerShell (`src/Mc.PowerShell`) owns anything a user might want to change without a rebuild.

**Panel.ps1 is a pure state machine.** A panel is a hashtable (`Location`, `Entries`, `Index`, `Top`, `Rows`, `Sort`, `Marked`...). Its functions mutate state and never draw or read keys. That is what makes every suite headless: build state with `New-McAppState`, call `Write-McFrame $screen $state` into an in-memory `[Mc.Native.Screen]`, inspect `$screen.Snapshot()` or the state. The renderer sets `Panel.Rows`, so call `Write-McFrame` once before paging keys mean anything.

**Sources are the extension point.** A panel holds a location string and asks a source (hashtable of scriptblocks: `Test`, `GetChildren`, `Descend`, `Parent`, `Title`, `Columns`) to turn it into rows. `Get-McPanelSource` picks the highest-priority source whose `Test` accepts the location. `FileSystem` (priority 100, enumerated in C#) and `PSProvider` (priority 10, anything `Test-Path` accepts) ship in `Sources.ps1`. Columns come from the source per location, so the renderer has no provider special-casing. An optional `Content` scriptblock supplies viewer lines for a leaf that is not a file, which is how a registry value or an `Env:` variable opens in the viewer. `Open` lets a source claim a file on Enter, `LeafName` names a location as its parent lists it, and `DefaultSort` applies until the user sorts: `Documents.ps1` uses all three to present a `.json` or XML file as a panel at `file.json::/pointer` or `file.xml::/element[2]`, mc's archive model. Register more with `Register-McPanelSource`.

**PowerShell's XML adapter shadows XmlNode properties.** `$element.Name` returns the child element called `<name>` if there is one. Read XmlNode properties through their getters, `$element.get_Name()`, `get_ChildNodes()`, `get_InnerText()`, as `Documents.ps1` does.

**Returning a .NET collection from a function unrolls it.** A JsonObject, a byte[] or a PanelEntry[] emitted from a function becomes its elements. Write `,$value` to return the object itself. `Get-McProp` does this; several bugs in this repository's history were this one thing.

**Key dispatch is a table.** `$script:McKeymap` in `App.ps1` maps canonical key name to `{ param($S, $Scr) ... }`. `Invoke-McKey` handles Enter specially (runs the command line if non-empty, else descends), then the keymap, then falls through to command-line editing for unclaimed keys. Anything modal (`Show-McList`, `Show-McMenu`, `Show-McViewer`, `Show-McDriveChooser`, the subshell) blocks on `[Mc.Native.Input]::Read` and cannot be driven headlessly; keep the logic they call (file loading, hit testing, layout) in separate functions that can.

**The viewer paints segments.** `Markdown.ps1` is a pure converter from source lines to formatted lines of `@{Text; Fg; Attr}` segments, always one per source line so line numbers and search are untouched. `Show-McViewer` paints segments in both modes; plain mode wraps each line in one segment. F9 toggles, as mc's Format key.

**Safety has two tiers, not one.** `Guard.ps1`: the app starts read-only and the mode is never persisted. `Assert-McWritable` is the absolute choke point; every mutating operation mc performs calls it first, and F5-F8 currently do only that. `Test-McCommandMutates` is the best-effort AST screen for the command line, output pane and subshell, plus `$WhatIfPreference`. Do not describe the screen as a sandbox; `docs/SAFETY.md` states the limits.

**The command line runs in this session.** `Invoke-McShellCommand`, `Invoke-McCommandInPane` and `Invoke-McSubshell` execute in the same PowerShell process, so location, variables and modules persist. `Terminal.Init`/`Shutdown` bracket the trip out to a full-screen shell.

## Conventions that lint or CI enforce

- Exported functions must be listed in both `Mc.psm1` (`Export-ModuleMember`) and `Mc.psd1` (`FunctionsToExport`); lint fails on drift either way.
- Never combine `Split-Path -LiteralPath` with `-Parent` or `-Leaf`; it is an invalid parameter set. Bare `-LiteralPath` returns the parent.
- `ModuleVersion` in `Mc.psd1` is the only version. `CHANGELOG.md` must keep an `[Unreleased]` section and a section for the current version. Release steps and what bumps what are in `docs/VERSIONING.md`; push at most three tags per push.
- A release tag `vX.Y.Z` must match the manifest or CI fails.

## Conventions the docs ask for

- **Parity with mc comes first.** Check the C on `reference` before deciding what a key does. Do not add convenience bindings mc lacks. When behaviour differs from mc, or something is Windows-only, record it in `docs/COMPAT.md` with an honest status (`done | partial | todo | different | wont-do`); do not overstate parity.
- Any new mutating operation starts with `Assert-McWritable`. Adding a cmdlet to the safe list in `Guard.ps1` needs a test in `tests/Guard.ps1` in the same commit.
- Write Windows-first; no abstraction for platforms not tested. Linux and macOS are frozen (`docs/PLATFORMS.md`), and `Mc.Native` stays netstandard2.0.
- New source files carry the GPL header used at the top of `Mc.psm1`.
- Silent failure is treated as a bug: a navigation or command that fails should set `$State.Message` saying why.
