# lunacmd

`lunacmd` is a Lua-first command-line environment.

- Default mode is Lua syntax and Lua execution.
- Shell-like command convenience is supported via builtins.
- User-defined builtins are supported from `~/.lunacmd/builtin`.
- Redirection and pipeline syntax is lunacmd-native (`:>`, `:<`, `:|`) to avoid Lua conflicts.
- Legacy shell symbols are opt-in with `:!`.

## Quick Start

1. Install dependencies:

```sh
sudo apt install build-essential libreadline-dev git make -y
```

2. Build Lua:

```sh
make lua
```

3. Build `lunacmd`:

```sh
make
```

Optional system-wide install:

```sh
sudo make install
```

4. Run:

```sh
./lunacmd
```

5. Run tests:

```sh
make test
```

## Example Session

```text
pwd
cd /tmp
echo hello :> out.txt
cat out.txt
source hello.lua
```

## Feature Quick Examples

```text
# persistent history + recall
history
!!
!12
!-2

# special buffers
echo hello :> :@mem
cat :< :@mem
lunabuffer status

# TUI mode
tui on
tui status
tui off
```

## Documentation

- `docs/getting-started.md`
- `docs/user-guide.md`
- `docs/language.md`
- `docs/builtins.md`
- `docs/development.md`
- `docs/architecture.md`
- `docs/lua-cheatsheet.md`

## Current Status

- Redirection is implemented (`:>`, `:>>`, `2:>`, `2:>>`, `2:>&1`, `:<`).
- Pipelines are implemented with `:|` and work across builtins and `exec`.
- Special redirection buffers are available: `:@mem` and `:@file` (managed by `lunabuffer`).
- Persistent history is implemented (`history`, `!!`, `!N`, `!-N`).
- Built-in TUI mode is available via `tui on|off|status`.
