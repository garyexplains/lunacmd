# Getting Started

## Prerequisites

- GCC toolchain
- GNU Make
- Readline development headers

On Ubuntu/Debian:

```sh
sudo apt install build-essential libreadline-dev -y
```

## Build

From the repository root:

```sh
make
```

This builds:

- `lunacmd` binary
- local Lua static library in `lua/src/liblua.a` (if needed)

## Run

```sh
./lunacmd
```

Exit with:

- `exit`
- `quit`

## Run Sanity Tests

```sh
make test
```

## First Commands

```text
pwd
ls
cd /tmp
echo hello world
date +%Y-%m-%d
```

## Lua Script Execution

Run Lua files explicitly with `source`:

```text
source hello.lua
```

## Notes

- `lunacmd` is Lua-first: normal lines are treated as Lua-friendly command input.
- Use lunacmd operators for redirection and pipeline parsing:
  - `:>`, `:>>`, `:<`, `:|`
- Special buffer targets are available for redirection/input:
  - `:@mem` and `:@file`
- Use `:!` prefix to opt into legacy shell symbols (`>`, `<`, `|`, etc.).
- Prompt customization (`PROMPT`, `PROMPT_CONT`) is documented in `docs/language.md`.
- Lua one-liners and quick tricks are in `docs/lua-cheatsheet.md`.
