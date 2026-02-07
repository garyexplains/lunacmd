# Architecture and Developer Guide

This document explains how `lunacmd` works internally and how to extend it safely.

## High-Level Runtime

`lunacmd` is a C host (`main.c`) embedding Lua 5.4.

Main responsibilities in C:

- REPL loop and readline integration
- parsing input into command AST
- command resolution and dispatch
- redirection/pipeline plumbing
- special buffer handling (`:@mem`, `:@file`)
- history persistence and recall expansion
- job control process management (`&`, `jobs`, `fg`, `bg`)
- TUI rendering support and key input bridge

Main responsibilities in Lua builtins:

- user-facing command behavior (`ls`, `cp`, `head`, `tail`, etc.)
- help text and argument semantics
- filesystem/text operations via Lua + host-provided helpers

## Core Execution Pipeline

Per input line, the runtime roughly does:

1. Read line (supports multiline continuation via trailing `\`).
2. Expand history events (`!!`, `!N`, `!-N`) when applicable.
3. Determine parser mode:
   - default Lua-first syntax
   - legacy syntax if line starts with `:!`
4. Parse into command AST (pipeline + redirections).
5. Detect background marker `&`.
6. Resolve/execute:
   - parent-stateful paths in parent process
   - command/builtin pipelines and non-stateful commands in child jobs
7. Update status and continue loop.

## Parser and AST

### Tokens

Parser recognizes words and operators.

Default operators:

- `:|`, `:<`, `:>`, `:>>`
- `2:>`, `2:>>`, `2:>&1`

Legacy operators are only accepted in `:!` mode.

### AST Structure

The AST is pipeline-centric:

- pipeline contains one or more command nodes
- each command has argv[] and redirections[]
- each redirection stores type + target

This allows one grammar path for single commands and pipelines.

### Why Lua-First Operators Exist

Lua uses `<` and `>` for comparison.

If shell operators were always active, common Lua lines would misparse.

The `:| :< :>` family keeps Lua code valid while preserving shell-like ergonomics.

## Command Resolution and Execution

Given first command token:

1. resolve core builtin (`builtin/<name>.lua`)
2. resolve user builtin (`~/.lunacmd/builtin/<name>.lua`)
3. fallback to Lua chunk execution

Helpers:

- `which` exposes command path resolution
- `type` exposes resolution class

### Lua Fallback Semantics

Foreground single-command Lua fallback runs in parent process so state persists:

```text
a = 1
print(a)   # prints 1
```

This behavior is required for Lua-first interactive workflows.

## Alias Expansion

Alias expansion is done before command resolution:

- alias value is parsed as plain words
- replacement prefix is prepended to remaining args
- recursion depth is bounded to prevent loops

Example:

- alias: `ll = ls -l`
- input: `ll /tmp`
- expanded argv: `ls -l /tmp`

## Backtick Substitution

Backticks in builtin command args/redirection targets are evaluated as Lua expressions.

Evaluation model:

- expression wrapped as `return <expr>`
- evaluated in current Lua state
- converted via `tostring(...)`

Important:

- applies to builtin/exec argument flow
- does not rewrite arbitrary Lua fallback program text

## Redirection Internals

Redirection is implemented by fd swapping around command execution.

Flow:

1. snapshot stdin/stdout/stderr fds
2. apply AST redirections in order
3. run command
4. restore original fds

Supported:

- stdin file / buffer redirection (`:<`)
- stdout/stderr file redirection (`:>`, `:>>`, `2:>`, `2:>>`)
- stderr to stdout (`2:>&1`)

### Special Buffer Integration

At redirection layer, targets `:@mem` and `:@file` are resolved centrally, so individual builtin scripts do not need custom support.

`lunabuffer` controls policy (size, clear, save) without changing command implementations.

## Pipeline Internals

Pipelines spawn per-stage child processes with pipe fds connecting stdout->stdin.

Stages run through same command path (builtin/user builtin/lua fallback where applicable).

Design consequence:

- pipeline stages are process-isolated
- Lua globals set in one stage do not persist to parent

## Job Control Internals

Job support is process-group based.

Key behaviors:

- trailing `&` marks background launch
- each launched job gets its own process group
- foreground handoff uses terminal process-group switching when stdin is a tty
- shell ignores interactive signals; child restores defaults

Builtins:

- `jobs` lists tracked jobs
- `fg %N` moves job to foreground and waits
- `bg %N` resumes stopped job

Job ID policy:

- IDs increment while jobs exist
- when job table becomes empty, next job ID resets to `1`

## History System

Readline history plus explicit persistence helpers:

- file path: `~/.lunacmd/history`
- load on startup
- write on shutdown
- runtime commands: `history -w`, `history -r`, `history -c`

History expansion integrates before parse.

## TUI Mode

TUI rendering is managed in `main.c` using terminal control sequences and window regions.

Current panes:

- files pane
- command/output pane
- history pane

TUI changes display behavior, not command semantics.

## Lua <-> C Bridge Functions

C exports helper functions into Lua globals (names prefixed `_`), used by builtins.

Representative helpers:

- filesystem info/listing/stat helpers
- sleep and single-char input helper
- command/path resolution helpers
- history helpers
- job helpers

Guideline:

- prefer adding low-level host primitives in C only when Lua cannot do the job portably/reliably
- keep command policy in Lua builtins

## Builtin Script Contract

Each builtin is a Lua file receiving conventional globals:

- `ARGC`
- `ARGS` (1-based array)
- `G_CWD`
- `CMD_SOURCE`
- `CMD_PATH`

Conventions:

- support `-h` and `--help`
- write errors to `io.stderr`
- resolve paths through `_RESOLVE_PATH` when available
- support stdin (`-` or no file args) where command semantics imply stream input

## Adding a New Builtin

Checklist:

1. create `builtin/<name>.lua`
2. implement behavior + help flags
3. ensure path handling (`_RESOLVE_PATH` / `G_CWD`)
4. verify stdin/pipeline behavior when relevant
5. add sanity tests in `tests/sanity.sh`
6. document command in `docs/builtins.md`

## Adding Parser Features

Checklist:

1. update tokenizer/operator matching logic
2. update AST parse logic and validation
3. update execution layer to honor new AST nodes
4. extend sanity tests (success + failure cases)
5. update `docs/language.md`

Avoid parser changes that break Lua-first guarantees.

## Testing Strategy

Primary regression suite:

```sh
./tests/sanity.sh
```

Or:

```sh
make test
```

Coverage includes:

- parser behavior
- redirection/pipeline
- buffers
- builtins help flags
- user builtins
- history/prompt behaviors
- job-control smoke checks

When touching runtime process code, run full sanity, not partial tests.

## Debugging Tips

### Validate command resolution

```text
which <cmd>
type <cmd>
```

### Isolate config effects

```sh
LUNACMD_NO_RC=1 ./lunacmd
```

### Disable user builtin overrides

```sh
LUNACMD_NO_USER_BUILTINS=1 ./lunacmd
```

### Check parse mode quickly

- default mode rejects legacy operators
- `:!` enables legacy operator parsing

## Design Rules to Preserve

1. Lua-first semantics come first.
2. Shell-like behavior is convenience, not identity.
3. Redirection/pipes should work without per-builtin plumbing.
4. Stateful Lua REPL behavior should remain intuitive.
5. Add tests before/with behavioral changes.

## Known Tradeoffs

- vendored Lua source tree increases repo size
- some terminal/TUI behavior may vary across environments
- job control is intentionally minimal (no full `bash` parity yet)

## Forward Work Areas

Potential next deepening areas:

- stronger parser diagnostics with token spans
- richer job states and notifications
- optional advanced completion for builtins/user builtins
- richer TUI interactions (selection, preview, command palette)
- expanded dev docs for C API boundaries and memory ownership map
