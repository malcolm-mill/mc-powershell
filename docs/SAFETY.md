# Safety modes

mc-powershell starts in **read-only mode** every time. The mode is never
persisted — there is no way to end up read-write because of something you did
last week.

The current mode is always on screen, as a badge at the left of the command
line. Read-write is deliberately alarming:

```
 RO  C:\projects>            green badge — nothing can be changed
 RW  C:\projects>            red badge  — changes are allowed
```

## Switching

Type these at the command line and press Enter. They are handled by mc itself
and never reach the shell.

| Command | Effect |
|---|---|
| `mc.ps1.ro` | Return to read-only |
| `mc.ps1.rw` | Ask to enable read-write — confirmation defaults to **No** |
| `mc.ps1.mode` | Report the current mode |

## Two guarantees, and they are not equally strong

This distinction matters. Do not conflate them.

### 1. mc's own operations — absolute

Every mutating operation mc performs goes through one choke point:

```powershell
Assert-McWritable -Operation 'Delete' -Target $path
```

It throws in read-only mode. This is enforced by construction: an operation
that does not call it does not exist, and the F5/F6/F7/F8 handlers call it
before they do anything else. There is no path around it, and the tests assert
that F5 and F8 are refused.

### 2. The command line — best effort

The command line runs arbitrary PowerShell. In read-only mode it gets two
layers of defence:

**Layer one — an AST screen.** `Test-McCommandMutates` parses the command and
refuses it if it finds:

- a cmdlet that changes state, after resolving aliases (`rm`, `del`, `ri` all
  resolve to `Remove-Item`), by explicit deny-list and by approved verb
- `mkdir` / `md`, which are functions with no verb to screen on
- output redirected to a file (`>`, `>>`) — but not `2>$null`, which discards
- assignment to `$env:ANYTHING`
- mutating .NET calls: `[IO.File]::Delete`, `WriteAllText`,
  `[Environment]::SetEnvironmentVariable`, and similar
- a **native executable**, refused as a category — its arguments cannot be
  analysed, so `cmd /c del x` and `robocopy` are refused rather than guessed at
- a command name computed at run time, or anything that does not parse

Ordinary read-only work is unaffected: `Get-ChildItem`, pipelines through
`Sort-Object` / `Where-Object` / `Format-Table`, `Set-Location`, `Select-String`
and friends all run normally.

**Layer two — `$WhatIfPreference`.** While a command runs in read-only mode,
`$WhatIfPreference` is set to `$true` in that scope. Any ShouldProcess-aware
cmdlet that slipped past the screen reports what it *would* do instead of doing
it.

### The limit, stated plainly

**A function body is not analysed.** Screening works on command names and verbs.
A function called `Get-Something` that deletes files internally will pass the
screen. `tests/Guard.ps1` contains an executed test recording exactly this, so
it is a known limit rather than an assumption.

This is a **seatbelt against mistakes, not a security boundary**. It reliably
stops you typing `rm *` out of habit while browsing. It will not stop code that
is trying to get around it. If you need a real boundary, run mc-powershell as a
user account that lacks write permission — that is enforced by the OS, and
nothing here can weaken it.

## For contributors

When you add a mutating operation in M3, the first line of it is
`Assert-McWritable`. If you find yourself wanting to skip it "just for this
one", that is the bug.

If you add a cmdlet to the safe list in `Guard.ps1`, add a test to
`tests/Guard.ps1` in the same commit showing it is genuinely read-only.
