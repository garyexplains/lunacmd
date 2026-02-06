# Builtins

This lists builtins currently present in `builtin/`.

## Navigation and Environment

- `pwd`
  - Prints current logical directory (`G_CWD`).
- `cd [DIR]`
  - Changes `G_CWD`.
  - `cd` without args uses `$HOME` if available.
- `source FILE`
  - Loads and executes a Lua file.
- `setprompt [--cont] TEXT...`
  - Sets `PROMPT` (or `PROMPT_CONT` with `--cont`) at runtime.
- `prompt`
  - Prints current prompt configuration.
- `which CMD...`
  - Prints resolved command path for each command (or `lua-fallback`).
- `type CMD...`
  - Prints resolution kind (core builtin, user builtin, lua fallback).

## Display and Utility

- `echo [ARG]...`
  - Prints args joined by spaces.
- `clear`
  - Clears the terminal screen with ANSI escape codes.
- `date [-u] [+FORMAT]`
  - Prints date/time via Lua `os.date`.

## Filesystem and File Content

- `ls [DIR]`
  - Lists directory entries (pure Lua + internal runtime helper).
- `cat FILE...`
  - Prints file contents.
- `mkdir [-p|--parents] DIR...`
  - Creates directories.
- `rm [-i|--interactive] [-f|--force] FILE...`
  - Removes files (not directories).
- `cp [-f|--force] [-i|--interactive] [-R|-r|--recursive] [-v|--verbose] SRC... DST`
  - Copies files/directories.
- `mv [-f|--force] [-i|--interactive] [-v|--verbose] SRC... DST`
  - Moves/renames files/directories.

## Text and Data Processing

- `cksum FILE...`
  - Prints CRC32, byte size, path.
- `fold [-s] [-w WIDTH] FILE...`
  - Wraps lines to width (`80` default).
  - `-s` prefers breaking at spaces.
- `wc [-c] [-m] [-l] [-w] [-L] FILE...`
  - Counts bytes/chars/newlines/words/longest-line.
  - Default output is `-l -w -c`.

## External Command Bridge

- `exec CMD [ARG]...`
  - Runs external OS command in current `G_CWD`.

## Timing

- `sleep [N]...`
  - Sleeps for total of durations.
  - Suffixes supported: `s`, `m`, `h`, `d`.

## Internal/Test Builtins

- `bad`
  - Intentionally invalid Lua script used for error-path testing.
- `inca`
  - Minimal/test script from early development.
