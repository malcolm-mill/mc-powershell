# Roadmap

Versioned by capability, not by date. Each milestone is usable on its own; none
of them is a "layer" that produces nothing you can run.

---

## M1 — Walking skeleton  *(done, 0.1)*

Two panels over the object model, navigable, with correct terminal lifecycle.

- [x] Double-buffered ANSI renderer with diff emit
- [x] Canonical key names, keymap dispatch table
- [x] Panel source contract; FileSystem + PSProvider sources
- [x] Per-provider columns with flex layout
- [x] Navigate, mark, sort, switch panel, resize, quit
- [x] F2 drive/provider chooser, F3 viewer, Ctrl+O shell-out
- [x] Headless render harness (`tests/Smoke.ps1`)

---

## M2 — Navigation and view  *(0.2)*

Make it pleasant to move around before making it able to destroy things.

- [ ] Quick search (type-to-filter within the panel)
- [ ] Brief / long / custom column layouts, toggled per panel
- [ ] Move the row-painting loop into C# (see the perf ceiling in ARCHITECTURE)
- [ ] Panel history, Alt+Y / Alt+U
- [ ] Directory hotlist
- [ ] Config persistence (panel paths, sort, hidden-files flag)
- [ ] Pester suite + golden-frame fixtures; CI on Windows/Linux/macOS

---

## M3 — File operations  *(0.3)*

The milestone most file managers get quietly wrong. Errors are the feature.

- [x] Safety modes: read-only by default, `Assert-McWritable` choke point,
      command-line screening (landed early, before anything could mutate --
      see [SAFETY.md](SAFETY.md))
- [ ] F5 copy, F6 move/rename, F7 mkdir, F8 delete
- [ ] Progress dialog with per-file and total, cancellable
- [ ] Overwrite prompts: yes / no / all / none / newer-only
- [ ] Error handling: skip / skip-all / retry / abort on every operation
- [ ] Long paths, read-only attributes, in-use files
- [ ] Operations expressed against the source contract, so they work on
      providers, not just the filesystem, wherever the provider supports it

---

## M4 — Shell integration  *(0.4)*

The hardest parity feature, and the one that makes it feel like mc.

- [ ] Command line running in the *same* PowerShell session, not a child
- [ ] Ctrl+O screen swap with the shell's scrollback preserved
- [ ] Macros: current file, other panel's path, marked files
- [ ] Tab completion on the command line
- [ ] Panel updates after a command changes the directory

---

## M5 — Viewer and editor  *(0.5)*

- [ ] F3 viewer: search, hex mode, wrap toggle, huge-file streaming
- [ ] F4 shells out to `$env:EDITOR` by default
- [ ] Internal editor is explicitly a separate project; do not let it eat this one

---

## M6 — Providers and archives  *(0.6)*

Where the thesis pays off. If M1's source contract was right, most of this is
new sources rather than new plumbing.

- [ ] Archive source: zip / tar browsing as a panel
- [ ] Object-aware actions: Enter on a `Cert:` entry shows the certificate,
      Enter on a `Function:` entry shows the definition
- [ ] Column picker: choose any property of the underlying object as a column
- [ ] Sort and filter by arbitrary object property, not just name/size/date
- [ ] Plugin discovery from `~/.mc-powershell/sources/*.ps1`

---

## M7 — Polish  *(1.0)*

1.0 means: it is the file manager I use every day.

- [ ] Skins / themes; read mc's `.ini` skin format
- [ ] F2 user menu, F9 pull-down menu bar
- [ ] Find file, compare directories, external panelize
- [ ] Publish to the PowerShell Gallery
- [ ] `docs/COMPAT.md` scorecard filled in

---

## Cross-cutting, from now on

- Every mc feature gets an issue, labelled by mc's own subsystem
  (`panel`, `vfs`, `editor`, `keybind`) and citing the file on `reference`.
- `docs/COMPAT.md` is the spec, the changelog, and the honest status report.
- Dogfood from M3 onward. Nothing else finds the papercuts.
- One asciinema recording per milestone in `demos/`.
