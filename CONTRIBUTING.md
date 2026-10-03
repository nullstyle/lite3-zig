# Contributing

## Setup

Install [mise](https://mise.jdx.dev) and [just](https://just.systems), then run
`mise install` in the repository. This installs the pinned Zig (0.17.0, see
`.mise.toml`). `just --list` shows all tasks.

## Before sending a change

```bash
just test-all       # Debug/ReleaseSafe/ReleaseFast, -Djson=false, upstream C tests,
                    # examples + README quick start, consumer package
zig build fmt       # formatting
zig build lint-c    # the project's own C files with -Werror
```

CI also runs valgrind, LTO, 32-bit musl, cross-compilation for several
targets, and a short fuzzing run; see `.github/workflows/ci.yml`.

For changes to reading, writing or validation code, also run:

- `just fuzz 1M` — coverage-guided fuzzing of all four targets.
- `just mutate` — mutation testing. Every mutant except the three equivalent
  ones listed in `scripts/mutate.py` should be killed. When you add a check,
  add a mutant for it.

## Tests

- Behaviour tests go in `src/api_tests.zig`, generic over all document types
  where possible (`test_util.backends`).
- A bug fix comes with a test that fails without it.
- `src/testdata/sample.lite3` locks the bytes the library writes. If you change
  them on purpose, regenerate it with `LITE3_UPDATE_GOLDEN=1 zig build test`
  from the repository root and note the format change in `CHANGELOG.md`.

## The vendored C library

`vendor/lite3/` is generated: never edit it by hand. It is upstream lite3 at
the commit in `vendor/lite3/UPSTREAM` plus the patches in `vendor/patches/`.
To change the C code:

1. Clone upstream lite3, check out the pinned commit, and apply the existing
   patches (`git am vendor/patches/*.patch`).
2. Commit your change on top, with a message that explains the bug.
3. Regenerate the series with
   `git format-patch -N --zero-commit --no-signature -o vendor/patches <pinned-commit>`.
4. Run `just update-vendor` and commit the result.

Report bugs in lite3 itself upstream as well (see `docs/upstream-issues.md`).

## Style

- Zig: `zig fmt`; doc comments on every public declaration.
- C: C11, no warnings under `zig build lint-c`.
- Commit messages: a short summary line, then what changed and why.
