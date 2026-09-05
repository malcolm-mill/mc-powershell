# The `reference` branch

`reference` holds the unmodified GNU Midnight Commander tree. It is never
merged into `main` and no code is copied out of it. It is there to be **read**:
when a question comes up about what mc actually does, the answer is in the C,
not in a recollection of using mc.

## Reading it without switching branches

```bash
# one file
git show reference:src/filemanager/panel.c | less

# search the whole tree
git grep -n 'sort_order' reference -- src/

# a persistent read-only checkout alongside your work
git worktree add ../mc-reference reference
```

## Where the answers live

| Question | File on `reference` |
|---|---|
| Panel state, sorting, marking, quick search | `src/filemanager/panel.c` |
| Screen layout, panel geometry, resize | `src/filemanager/layout.c` |
| Copy / move / delete, progress, error dialogs | `src/filemanager/file.c` |
| Command dispatch (what the F-keys actually call) | `src/filemanager/cmd.c` |
| Find-file dialog and panelize | `src/filemanager/find.c` |
| Key names and the keymap parser | `src/keymap.c` |
| Default keybindings | `misc/mc.default.keymap` (`misc/mc.keymap` is just a pointer to it) |
| VFS interface — the shape our source contract echoes | `lib/vfs/interface.c`, `lib/vfs/vfs.c` |
| Path handling across VFS layers | `lib/vfs/path.c` |
| Directory entry caching | `lib/vfs/direntry.c` |

## Licence consequence

mc is GPL-3.0-or-later. This repository is a fork of it, so `main` is
GPL-3.0-or-later too. That is a deliberate choice, not an accident: it keeps
mc's keymaps, skin files and documentation available as source material with no
provenance argument to have.

New files on `main` should carry:

```
# mc-powershell : Midnight Commander's UI over PowerShell's object model.
# Copyright (C) 2026  Malcolm Mill
# Licensed under the GNU General Public License v3 or later. See COPYING.
```
