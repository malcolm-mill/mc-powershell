# Versioning

mc-powershell uses [Semantic Versioning 2.0.0](https://semver.org). The version
lives in exactly one place, `ModuleVersion` in `src/Mc.PowerShell/Mc.psd1`;
everything else reads it from there (`mc -Version`, `Get-McVersion`, the lint
suite, the CI tag check).

## The 0.x line is pre-release

Every version below 1.0.0 is pre-release and not considered shippable. SemVer
says the same thing about major version zero: "anything MAY change at any
time; the public API SHOULD NOT be considered stable". Key bindings, the panel
source contract, exported functions and on-disk state can all change between
0.x versions.

1.0.0 is milestone M7 in [ROADMAP.md](ROADMAP.md): "the file manager I use
every day". Nothing short of that gets a 1.

## What bumps what

While on 0.x:

| Bump | When | Examples |
|---|---|---|
| **minor** `0.Y.0` | Anything a user would notice as new or different | A new key, a new panel source, a changed binding (Backspace no longer navigating), a dropped platform |
| **patch** `0.y.Z` | Fixes only; nothing new, nothing removed | A key that did not arrive, a loader that skipped a rebuild, a test that assumed the local checkout name |

Documentation-only and test-only commits do not bump anything on their own;
they ride along with the next release.

From 1.0.0 the usual rules apply: **major** for any incompatible change to
key bindings, the source contract or exported functions; **minor** for
additions; **patch** for fixes. Release candidates on the way to 1.0.0 use
SemVer pre-release identifiers, `1.0.0-rc.1`, in both the manifest's
`PrivateData.PSData.Prerelease` field and the tag.

## Milestones are not versions

The roadmap's milestones (M1 ... M7) are groups of capabilities, and things
land out of order: the viewer was M5 and shipped in 0.3.0; the subshell was M4
and shipped in 0.2.0. So a milestone finishing does not itself bump anything.
A release is cut when there is a coherent batch worth naming, and the
[CHANGELOG](../CHANGELOG.md) says what was in it.

## Cutting a release

1. Set `ModuleVersion` in `src/Mc.PowerShell/Mc.psd1`.
2. Move the `[Unreleased]` items in `CHANGELOG.md` under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading and add its compare link at the bottom.
3. Run `./tests/Lint.ps1`. It checks the version is `MAJOR.MINOR.PATCH`, that
   the changelog has a section for it, and that `Get-McVersion` agrees.
4. Commit, then tag with an annotated tag whose name is `v` plus the version:

   ```
   git tag -a v0.6.0 -m "v0.6.0"
   git push origin main --follow-tags
   ```

CI runs on tag pushes too and fails if the tag and the manifest disagree, so a
mistyped tag cannot become a release.

Push at most three tags in one push. GitHub creates no push events when more
than three tags arrive together, so the tag check silently never runs. That is
what happened when the first six tags went up at once; v0.5.0 had to be
deleted from the remote and pushed again on its own before its run appeared.

Tags are annotated, never lightweight, so `git describe` works and the tag
carries its own date and author.

## History

Versioning was adopted on 2026-09-06 at 0.5.0. The tags before it (v0.1.0
through v0.4.0) were placed after the fact on the commits that closed each
coherent batch; the manifest inside those commits still reads 0.1.0, because
history is not rewritten. The CHANGELOG reconstructs what each contained from
the commit messages.
