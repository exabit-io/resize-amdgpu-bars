# Vendored bash style fixture

Dave Eddy's bash style guide, as enforced by the `t02_style.sh` conformance
test of Nikolas Britton's `bash_goto` project. The checks (tabs, 80 columns
at tab stop 8, no runs of blank lines, no trailing whitespace, `[[ ]]` only,
no backtick substitution, no trailing semicolons, no `function`/`let`/
`readonly`/`seq`, no `eval`, `shellcheck -S style` clean) are the ones the
7.0 formatting pass (to-do §7) has to satisfy.

| | |
|---|---|
| Source | https://github.com/nbritton/bash_goto |
| Tag / commit | v1.0.2, `7ea7fb9e02795a084e602d1424cd439755a13140` (2026-07-25) |
| Fetched | 2026-09-02 by `git clone` |
| Licence | MIT, `LICENSE` in this directory is upstream's file, unmodified |
| Style guide | https://github.com/bahamas10/bash-style-guide (Dave Eddy, MIT); upstream vendors it as `bash-style-guide.md`, not copied here |

## Files

| file | upstream path | upstream commit of that file | local changes |
|---|---|---|---|
| `t02_style.sh` | `test/t02_style.sh` | `5af07ab64f8f` | yes, see below and `local-changes.patch` |
| `lib.sh` | `test/lib.sh` | `f52930df18d8` | none |
| `mask.sh` | `goto.sh`, function `__gt_mask` (lines 418-779) | `7ea7fb9e0279` | extracted verbatim; a file header and a file-level `shellcheck disable=SC2034,SC1003,SC2016` were added (upstream disables the same at the top of `goto.sh`) |
| `LICENSE` | `LICENSE` | `7ea7fb9e0279` | none |
| `run.sh` | (local) | - | wrapper: `tests/style/run.sh FILE...` |

## Local changes to `t02_style.sh`

Every change is marked `LOCAL:` in the file; `local-changes.patch` is the
`diff -u` against the upstream file.

1. The files to check come from the command line (`files=("$@")`) instead
   of the hard-coded `bash_goto` repository layout, and are reported by the
   path given. The `cd` into the fixture directory is gone for the same
   reason; `lib.sh` and `mask.sh` are sourced by path.
2. The masker is sourced from `mask.sh` instead of `source goto.sh --lib`.
3. The shebang check compares against `$STYLE_SHEBANG`, default
   `#!/bin/bash`. The style guide wants `#!/usr/bin/env bash`; this package
   deliberately ships `#!/bin/bash` because Debian policy requires an
   absolute interpreter path for packaged scripts and the program can only
   run on Linux anyway (to-do §0, "two deliberate deviations"). Export
   `STYLE_SHEBANG='#!/usr/bin/env bash'` to check a file the upstream way.
4. Upstream exempts its two runtimes (`goto.sh`, `goto_trap.sh`) from the
   `eval` check; nothing is exempt here.

## Running

    tests/style/run.sh resize_gpu_bars.sh
    tests/style/run.sh resize_gpu_bars.sh tests/test_resize_gpu_bars.sh

Output is TAP-like (`ok N - ...` / `not ok N - ...`, failing line numbers in
`#` comments, a final `# pass=X fail=Y` line); the exit status is 0 only
when everything passes. `shellcheck` is run with `-x -P SCRIPTDIR -S style`
when installed and skipped otherwise. To lint the fixture itself use the
same flags, so that its `# shellcheck source=` directives resolve:

    shellcheck -x -P SCRIPTDIR -S style tests/style/*.sh

## Updating

    git clone https://github.com/nbritton/bash_goto /tmp/bash_goto
    cp /tmp/bash_goto/test/lib.sh /tmp/bash_goto/LICENSE tests/style/
    diff -u /tmp/bash_goto/test/t02_style.sh tests/style/t02_style.sh
    # re-apply the LOCAL: changes, regenerate local-changes.patch,
    # re-extract __gt_mask into mask.sh, update the table above
