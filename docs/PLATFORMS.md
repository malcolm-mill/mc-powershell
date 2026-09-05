# Supported platforms

**Windows is the only supported platform.** Linux and macOS are *frozen*, not
removed.

## What that means

| | Status |
|---|---|
| Windows (PowerShell 7.2+, Windows Terminal or conhost) | Supported, tested in CI |
| Linux, macOS | Frozen — not built, not tested, not supported |

CI runs `windows-latest` only. The Linux and macOS jobs are commented out at the
top of `.github/workflows/ci.yml` with the matrix needed to restore them, so
unfreezing is a two-line edit rather than an archaeology exercise.

## There is no separate "mac/linux compile target" to remove

Worth being precise, because it is easy to assume otherwise: `Mc.Native` targets
`netstandard2.0`, which is not a platform target. It compiles once into one
assembly that any .NET runtime loads. There was never a per-platform build to
delete, and narrowing it to a Windows-specific target framework would gain
nothing — no smaller output, no faster build, no new API we currently use.

So the target framework stays as it is. The only thing that actually changed is
that CI no longer builds and tests on three operating systems.

## The portability that remains, and why

Two pieces of code still have non-Windows paths. Both stay, because they earn
their place on Windows alone:

- **`Input.cs` fallback.** The Windows backend reads the console input queue
  through `ReadConsoleInput`. If that setup fails — input redirected, an unusual
  host, a terminal that will not give up QuickEdit — it falls back to
  `Console.ReadKey`. That fallback is what keeps a bad console from breaking the
  app entirely, and it happens to be the same code path Linux would use.
- **Path handling.** `Get-McParentPath` and `Get-McLeafName` accept both slash
  characters. Windows accepts forward slashes in paths, and PowerShell providers
  such as `Env:` and `HKLM:` are not filesystem paths at all, so this is not
  Unix support — it is correctness on Windows.

Neither is a maintenance burden and neither is worth ripping out to prove a
point.

## The rule going forward

Write Windows-first. Do not add abstraction for platforms we do not test.

But when something genuinely only works on Windows — mouse input is the current
example, since it needs `ReadConsoleInput` and Linux would need an SGR decoder
for VT input — record it in [COMPAT.md](COMPAT.md). That keeps the cost of
unfreezing visible instead of letting it accumulate silently into a rewrite.
