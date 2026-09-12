# Compatibility scorecard

Every Midnight Commander keybinding, and where this project stands on it.
This file is the spec. Keep it honest — "different" and "won't do" are
legitimate answers, silence is not.

Source of truth for mc's defaults: `misc/mc.default.keymap` on the `reference`
branch. (`misc/mc.keymap` is only a one-line pointer to it.)

Windows is the only supported platform; anything Windows-specific is recorded
here so the cost of unfreezing the others stays visible. See
[PLATFORMS.md](PLATFORMS.md).

**Status values:** done | partial | todo | different | wont-do

## Panel navigation

| Key | mc behaviour | Status | Notes |
|---|---|---|---|
| Up / Down | Move cursor | done | |
| PgUp / PgDn | Page | done | |
| Home / End | First / last entry | done | |
| Enter | Descend, or execute file | different | Descends. On a file it opens the viewer for text, and says so for a binary or a provider item. Never executes: nothing in mc-powershell runs a file, and read-only mode could not guard it |
| Ctrl+PgUp | Parent directory (`[panel] CdParent`) | done | mc's actual binding |
| Backspace | Delete a character on the command line (`[input]`) | done | |
| Backspace on an empty command line | Nothing (`[panel]` binds no Backspace) | done | Was "go up a directory" until 2026-09-06; removed for parity |
| Ctrl+H | Same as Backspace (`[input]`) | done | |
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
| F3 | View | done | Built-in viewer: encoding detection, wrap, line numbers, goto, search, markdown formatting with F9 as mc's Format toggle. Hex mode is later |
| F4 | Edit | todo | Will shell out to EDITOR first |
| F5 | Copy | todo | M3 |
| F6 | Rename / move | todo | M3 |
| F7 | Mkdir | todo | M3 |
| F8 | Delete | todo | M3 |
| F9 | Pull-down menu | done | Left / File / Command / Options / Right, keyboard and mouse |
| F10 | Quit | done | |
| Alt+F1 / Alt+F2 | Left / right drive chooser | todo | F2 covers the active panel |

## Panel display

| Feature | Status | Notes |
|---|---|---|
| Sort by name / extension / size / mtime | done | Left and Right menus |
| Reverse sort | done | Re-pick the same field |
| Brief / long / custom listing | todo | M2 |
| Columns per provider | done | **Beyond mc** — mc has no equivalent |
| Mini-status line | done | |
| Output lines pane | done | Ctrl+Up / Ctrl+Down. **Beyond mc** off Linux: mc reads the physical console buffer, so its version is console-only |
| Marked-file totals | done | |
| Directory sizes (Ctrl+Space) | todo | |

## Shell

| Feature | Status | Notes |
|---|---|---|
| Command line under the panels | done | Runs in place into the output pane when it is open, otherwise full-screen |
| Ctrl+O screen swap | done | Full-screen shell in the panel's directory; Ctrl+O again returns, as in mc, and the panel follows any `cd` (mc's `do_possible_cd`). Extra: `exit` at the prompt also returns; in mc it kills the subshell |
| Line editing in the subshell | partial | Our own key-by-key reader: characters, Backspace, Esc clears, Ctrl+C abandons the line. No cursor movement, history or completion yet (M4) |
| Same-session state (cwd, variables) | done | Commands run in this PowerShell session, so state persists without a pty subshell |
| Macros for current file / other panel | todo | M4 |
| Tab completion | todo | M4 |

## Mouse

| Feature | Status | Notes |
|---|---|---|
| Click the function key bar | done | **Beyond mc** -- mc supports mouse in panels but the key bar is the point here, since F-keys are widely hijacked |
| Click a menu title / item | done | |
| Click to focus a panel and select a row | done | |
| Click the selected row to descend | done | Double-click works too |
| Wheel scrolls the panel under the pointer | done | |
| Mouse off Windows | wont-do | Windows is the only supported platform ([PLATFORMS.md](PLATFORMS.md)). Would need an SGR decoder for VT input |

## VFS

| Feature | Status | Notes |
|---|---|---|
| Any PSProvider as a panel | done | **Beyond mc**. Registry keys and values share a listing, as directories and files do; certificates are listed by name, issuer and expiry; Enter on a value, a variable, a function or a certificate shows it in the viewer |
| Archives (zip, tar) | todo | M6 |
| JSON documents as a panel | done | **Beyond mc**. Enter on a `.json` file descends into its structure at `file.json::/pointer`; Ctrl+PgUp exits to the directory as from an archive |
| XML documents as a panel | todo | Same mechanism; elements, `@attribute` rows and `#text` |
| FTP / SFTP / SHELL | wont-do | PowerShell modules mount these as drives; the PSProvider source gets them for free |
| extfs scripts | wont-do | Superseded by the source contract |
