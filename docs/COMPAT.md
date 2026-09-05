# Compatibility scorecard

Every Midnight Commander keybinding, and where this project stands on it.
This file is the spec. Keep it honest — "different" and "won't do" are
legitimate answers, silence is not.

Source of truth for mc's defaults: `misc/mc.keymap` on the `reference` branch.

**Status values:** done | partial | todo | different | wont-do

## Panel navigation

| Key | mc behaviour | Status | Notes |
|---|---|---|---|
| Up / Down | Move cursor | done | |
| PgUp / PgDn | Page | done | |
| Home / End | First / last entry | done | |
| Enter | Descend, or execute file | partial | Descends; no execute yet |
| Backspace | Parent directory | done | |
| Tab | Other panel | done | |
| Insert | Mark and advance | done | |
| Plus / Minus / Star | Select / unselect / invert by pattern | todo | |
| Alt+. | Toggle hidden files | done | |
| Ctrl+R | Reload | done | |
| Ctrl+U | Swap panels | done | |
| Alt+Y / Alt+U | Panel history back / forward | todo | |
| Ctrl+Backslash | Directory hotlist | todo | |
| Alt+Shift+H | Directory history | todo | |
| type-ahead | Quick search | todo | M2 |

## Function keys

| Key | mc | Status | Notes |
|---|---|---|---|
| F1 | Help | todo | |
| F2 | User menu | different | Currently the drive/provider chooser — the project's headline feature earns the slot. User menu moves to the F9 menu bar. |
| F3 | View | partial | Text only; no search, no hex |
| F4 | Edit | todo | Will shell out to EDITOR first |
| F5 | Copy | todo | M3 |
| F6 | Rename / move | todo | M3 |
| F7 | Mkdir | todo | M3 |
| F8 | Delete | todo | M3 |
| F9 | Pull-down menu | different | Currently the sort menu |
| F10 | Quit | done | |
| Alt+F1 / Alt+F2 | Left / right drive chooser | todo | F2 covers the active panel |

## Panel display

| Feature | Status | Notes |
|---|---|---|
| Sort by name / extension / size / mtime | done | F9 |
| Reverse sort | done | Re-pick the same field |
| Brief / long / custom listing | todo | M2 |
| Columns per provider | done | **Beyond mc** — mc has no equivalent |
| Mini-status line | done | |
| Marked-file totals | done | |
| Directory sizes (Ctrl+Space) | todo | |

## Shell

| Feature | Status | Notes |
|---|---|---|
| Command line under the panels | partial | Runs, but as a shell-out not a live subshell |
| Ctrl+O screen swap | partial | Runs and returns; not a true screen swap |
| Same-session state (cwd, variables) | todo | M4 — the hard one |
| Macros for current file / other panel | todo | M4 |
| Tab completion | todo | M4 |

## VFS

| Feature | Status | Notes |
|---|---|---|
| Any PSProvider as a panel | done | **Beyond mc** |
| Archives (zip, tar) | todo | M6 |
| FTP / SFTP / SHELL | wont-do | PowerShell modules mount these as drives; the PSProvider source gets them for free |
| extfs scripts | wont-do | Superseded by the source contract |
