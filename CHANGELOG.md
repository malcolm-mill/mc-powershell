# Changelog

All notable changes to mc-powershell. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions
follow [Semantic Versioning](https://semver.org); see
[docs/VERSIONING.md](docs/VERSIONING.md) for what bumps what. Everything on the
0.x line is pre-release.

## [Unreleased]

### Added
- JSON documents as panels. Enter on a `.json` file descends into it as mc
  descends into an archive: objects and arrays are containers, values are
  leaves, with Name, Type and Value columns in document order. The location
  is `file.json::/json/pointer`; Ctrl+PgUp from the top exits to the
  directory with the cursor on the file. Enter or F3 on a value shows it,
  F3 on a container shows the subtree as indented JSON. Documents are parsed
  once and cached; a broken file is refused with the parser's message.
- Sources can claim a file on Enter (`Open`), name their own location in the
  parent listing (`LeafName`), and ask for a default sort (`DefaultSort`),
  which is how a document keeps document order until the user sorts.

## [0.8.0] - 2026-09-12

### Added
- Certificates are named by what they say. A `Cert:` panel shows each
  certificate's friendly name or subject, who issued it (or "self-signed"),
  and when it expires, instead of its thumbprint. Enter or F3 shows the
  full certificate: subject, issuer, validity, private key, serial,
  thumbprint, key and signature algorithms, purposes and alternative names.

### Fixed
- Choosing `Cert:` in the drive chooser opened the root of the current
  filesystem drive instead of the certificate stores. The drive reports its
  root as `\`, which `Test-Path` accepts; the chooser now trusts a drive's
  root only for the filesystem provider.

## [0.7.0] - 2026-09-12

### Added
- Registry values are rows. A registry panel lists a key's values as leaf
  rows under its subkeys, with Name, Type and Data columns; keys show their
  subkey and value counts. Enter or F3 on a value shows it in the viewer,
  with a hex dump for binary data and the expanded form for `REG_EXPAND_SZ`.
- Sources can supply viewer content for a leaf that is not a file (the
  `Content` scriptblock). The provider source uses it for registry values,
  and for anything with a Value or Definition, so Enter on an `Env:` variable
  or a `Function:` shows it instead of "not a file on disk".

### Fixed
- Enter on a registry subkey (or any non-filesystem container) now opens
  it. The provider source built the child path with `Convert-Path`, which
  strips the drive on every provider but the filesystem, so nothing could
  navigate to the result.
- A navigation that fails now says why on the message line instead of
  silently staying put.
- A container the account cannot read, such as `HKLM:\SECURITY`, is refused
  with the provider's error rather than shown as an empty key.

## [0.6.0] - 2026-09-12

### Added
- Markdown in the viewer: a `.md` file opens formatted, with headings,
  bold, italic (underlined, as mc's nroff mode does), code, links, lists,
  quotes, rules and tables. F9 toggles formatted and raw, mc's Format key.
  Formatting keeps one line per source line, so line numbers, go to line
  and search are unchanged.
- Enter, or a click on the highlighted row, opens a text file in the viewer.
  A binary file or a provider item (`Env:`, `HKLM:`) gets a message instead.
  mc executes the file here; mc-powershell never executes anything, so this
  is recorded in `docs/COMPAT.md` as a deliberate difference.

### Fixed
- F3 on an `Env:` variable no longer tries to open it as a file: the viewer
  now checks the path belongs to the FileSystem provider.

## [0.5.0] - 2026-09-06

### Added
- Semantic versioning: `docs/VERSIONING.md`, this changelog, `mc -Version`,
  `Get-McVersion`, lint checks that the manifest, changelog and code agree,
  and a CI check that a pushed tag matches the manifest.
- Ctrl+O inside the subshell returns to the panels, as mc's toggle does.
  `exit` and `quit` remain as aliases.
- A key-by-key line reader for the subshell: characters, Backspace, Esc clears
  the line, Ctrl+C abandons it, Ctrl+D on an empty line returns.

### Changed
- Backspace never navigates to the parent, on any provider. It only deletes a
  command-line character, matching mc's `[input]` binding. Ctrl+PgUp is the
  only way up. Ctrl+H, as its alias, changed with it.
- Milestone headings in the roadmap no longer double as version numbers.

## [0.4.0] - 2026-09-05

### Added
- Ctrl+PgUp goes to the parent directory, mc's actual `CdParent` binding.
  Ctrl+H is bound alongside Backspace, as mc's `[input]` section has it.
- `tools/Install-McCommand.ps1` installs a global `mc` command into the
  PowerShell profile, with `-Uninstall`.
- `tests/Keys.ps1` covers the whole key path from raw Windows key event to
  dispatch, and `tools/keytest.ps1` shows what a real terminal delivers.
- `tests/Lint.ps1`: every file parses, no invalid `Split-Path` parameter
  combinations, manifest exports match the module, every suite is in CI.
- `docs/PLATFORMS.md`.

### Changed
- Windows is the only supported platform. Linux and macOS CI jobs are frozen,
  with the matrix kept in the workflow so they can be restored.
- `docs/COMPAT.md` stops claiming Backspace-to-parent is mc behaviour.

### Fixed
- Alt+punctuation keys, such as Alt+. for hidden files, never arrived.
- A failed `ReadConsoleInput` left the keyboard dead for the rest of the
  session; it now falls back to `Console.ReadKey`.
- The module loader skipped rebuilding when a session already held an older
  assembly, and then failed on a type that assembly never had.
- Console input structs are now blittable, so the native layout is exact.

## [0.3.0] - 2026-09-05

### Added
- Menu bar: Left / File / Command / Options / Right, opened with F9 or the
  mouse.
- Mouse support via `ReadConsoleInput`: clickable key bar, menus and panels,
  wheel scrolling.
- A real F3 viewer: encoding detection, binary detection, wrap, line numbers,
  goto line, search with n/N.
- `tests/Interface.ps1`, 40 headless assertions over layout, mouse and viewer.

### Fixed
- The build loop: the assembly is shadow-copied before loading so a running
  session no longer blocks the next `dotnet build`.

## [0.2.0] - 2026-09-05

### Added
- Safety modes: read-only by default, `Assert-McWritable` as the choke point
  for mc's own operations, and an AST screen plus `$WhatIfPreference` for the
  command line. `mc.ps1.ro` / `mc.ps1.rw` / `mc.ps1.mode` switch and report.
  `docs/SAFETY.md` states the limits.
- Ctrl+O full-screen subshell running in the same PowerShell session, with
  the panel following any `cd` on return.
- Output pane under the panels (Ctrl+Up / Ctrl+Down), with commands run in
  place.
- `New-McAppState`, so the app and the test suites share one state shape.
- `tests/Guard.ps1`.

### Fixed
- A command name that could not be resolved threw out of the screen instead
  of being refused.

## [0.1.1] - 2026-09-05

### Added
- `tests/KeySequence.ps1`: scripted key sequences against the headless state
  machine. CI on push and pull request.
- `Get-McParentPath`, `Get-McLeafName` and the panel operations are exported.

### Fixed
- `Split-Path -LiteralPath X -Parent` is not a valid parameter set; it broke
  Backspace and Enter on `..` for every provider.
- A frame assertion hardcoded the local checkout's directory name.
- Backspace was bound unconditionally and shadowed command-line editing.

## [0.1.0] - 2026-09-05

### Added
- M1 walking skeleton: two panels over PowerShell's object model, with
  FileSystem and PSProvider sources and per-provider columns.
- C# native layer: double-buffered ANSI renderer, terminal lifecycle,
  canonical key names, fast filesystem enumeration.
- Navigate, mark, sort, switch panel, resize, F2 drive/provider chooser,
  F3 viewer, Ctrl+O shell-out, F10 quit.
- `tests/Smoke.ps1` headless render harness.

[Unreleased]: https://github.com/malcolm-mill/mc-powershell/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/malcolm-mill/mc-powershell/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/malcolm-mill/mc-powershell/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/malcolm-mill/mc-powershell/releases/tag/v0.1.0
