# Development

This document focuses on building, testing, and hacking on `lunacmd`.

For internal architecture details, see `docs/architecture.md`.

## Prerequisites

Minimum local requirements:

- GCC toolchain
- GNU Make
- readline headers/library

Ubuntu/Debian:

```sh
sudo apt install build-essential libreadline-dev -y
```

## Build

From repo root:

```sh
make
```

Build output:

- `./lunacmd`
- Lua static library in `lua/src/liblua.a`

## Test

Run all sanity tests:

```sh
make test
```

Equivalent:

```sh
./tests/sanity.sh
```

Recommendation:

- run full sanity after parser/execution/runtime changes
- run full sanity before commits

## Runtime Flags and Environment

- `LUNACMD_NO_RC=1`
  - skip loading `~/.lunacmd.lua`
- `LUNACMD_NO_USER_BUILTINS=1`
  - disable `~/.lunacmd/builtin` lookup

Useful for deterministic testing and debugging.

## Repo Layout

- `main.c`
  - host runtime, parser, execution, redirection/pipeline, history, job control, tui
- `builtin/`
  - core builtin Lua scripts
- `tests/sanity.sh`
  - integration-style sanity checks
- `docs/`
  - user and developer docs
- `lua/`
  - vendored Lua source tree

## Editing Workflow

Suggested loop:

1. change runtime or builtin code
2. run `make`
3. run `./tests/sanity.sh`
4. manually exercise changed behavior
5. update docs for user-visible changes

## Builtin Implementation Conventions

For `builtin/*.lua`:

- support `-h` and `--help`
- print usage as first line: `usage: ...`
- prefer pure Lua logic where practical
- use `io.stderr:write(...)` for errors
- honor stdin (`-` or empty input) for stream commands
- resolve relative paths against `G_CWD`/`_RESOLVE_PATH`

## Runtime Semantics to Keep Stable

### Lua-first behavior

- plain Lua lines should remain valid
- `<`, `>`, `|` legacy parsing must remain opt-in (`:!`)

### Explicit external execution

- external commands should continue to flow through `exec`
- fallback remains Lua code execution

### Stateful foreground Lua

- foreground single-command Lua fallback must run in parent state

## Job Control Notes

Current job control features:

- background via trailing `&`
- `jobs`, `fg`, `bg`
- process-group handling and foreground terminal handoff

Important behavior:

- job IDs reset to `%1` when all jobs are gone

## Redirection and Buffer Notes

Redirection and special buffers are implemented centrally in runtime code.

Benefits:

- builtins do not each need custom `:@mem` / `:@file` logic
- future commands inherit the feature automatically

If you touch redirection code:

- verify file targets
- verify stderr routes
- verify buffer read/write paths
- verify mixed pipeline + redirection flows

## Parser Change Checklist

When modifying grammar/tokens:

1. update tokenizer
2. update AST construction rules
3. validate error messages for malformed inputs
4. add tests for valid and invalid cases
5. update `docs/language.md`

## Test Authoring Tips

Use descriptive assertions in `tests/sanity.sh`:

- one behavior per assertion when possible
- include both positive and negative checks
- prefer deterministic temp-directory fixtures

When adding a builtin:

- include usage/help checks
- include normal-path behavior
- include common failure-path behavior
- include pipeline/stdin behavior if relevant

## Manual Smoke Tests

Examples after runtime changes:

```text
# Lua-first parse safety
a=1
if a < 2 then print("ok") end

# lunacmd operators
echo hi :> /tmp/x
cat :< /tmp/x
echo hi :| wc -w

# legacy opt-in
:! echo hi > /tmp/y

# buffers
echo hello :> :@mem
cat :< :@mem
```

After job-control changes:

```text
sleep 2s &
jobs
fg %1
```

## Release Hygiene

Before tagging/release cut:

1. ensure clean `git status`
2. run full sanity tests
3. update README/docs for shipped features
4. verify branch merge status
5. tag with meaningful version notes

## Embedded Lua Version

`lunacmd` currently vendors Lua `5.4.7` in the repository (`lua/` and `lua-5.4.7.tar.gz`).

Most development work does not require manually downloading Lua, because sources are present and `make` builds against the vendored tree.

### Rebuilding Vendored Lua Manually

```sh
curl -L -R -O https://www.lua.org/ftp/lua-5.4.7.tar.gz
tar zxf lua-5.4.7.tar.gz
mv lua-5.4.7 lua
cd lua
make all test
```

Then from repo root:

```sh
make
make test
```

## Future Direction

Shipping a vendored Lua version is probably not the best long-term approach.

In the future, we plan to replace this with a better automated workflow that fetches and integrates the latest Lua version.
