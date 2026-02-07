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
- `alias`
  - Manage command aliases.
  - Examples:
    - `alias less = more`
    - `alias lstmp = ls /tmp`
    - `alias` (list aliases)
    - `alias name` (show one alias)
- `setprompt [--cont] TEXT...`
  - Sets `PROMPT` (or `PROMPT_CONT` with `--cont`) at runtime.
- `prompt`
  - Prints current prompt configuration.
- `lunabuffer`
  - Manage special redirect buffers:
    - `lunabuffer status`
    - `lunabuffer size [N[K|M]]`
    - `lunabuffer clear [mem|file|all]`
    - `lunabuffer save <mem|file> FILE`
- `which CMD...`
  - Prints resolved command path for each command (or `lua-fallback`).
- `type CMD...`
  - Prints resolution kind (core builtin, user builtin, lua fallback).
- `history [N]`
  - Shows command history.
  - `history -c` clears history.
  - `history -w` writes history to disk.
  - `history -r` reloads history from disk.
- `tui on|off|status`
  - Enables/disables the built-in 3-pane terminal UI layout.

## Display and Utility

- `echo [ARG]...`
  - Prints args joined by spaces.
- `clear`
  - Clears the terminal screen with ANSI escape codes.
- `date [-u] [+FORMAT]`
  - Prints date/time via Lua `os.date`.

## Filesystem and File Content

- `ls [FILE]...`
  - Pure-Lua `ls` with shell-style options for long format, sorting, recursion, indicators, color, and human-readable sizes.
- `cat FILE...`
  - Prints file contents.
- `mkdir [-p|--parents] DIR...`
  - Creates directories.
- `rm [-i|--interactive] [-f|--force] FILE...`
  - Removes files (not directories).
- `rmdir [-p|--parents] DIR...`
  - Removes empty directories.
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
- `hexdump [-x] [FILE]...`
  - Default: hex + ASCII display.
  - `-x`: raw hex-only output.
  - Supports files and stdin (`-` or no file args).
- `more [FILE]...`
  - Pure-Lua pager with `less`-style basic controls in interactive mode:
    - `space` (next page), `enter` (next line), `b` (back page), `/` (search), `n` (next match), `q` (quit)
  - In non-interactive mode, prints all content.
  - Supports files and stdin (`-` or no file args).
- `head [FILE]...`
  - Prints first 10 lines by default.
  - `-n N[kbm]`: first N lines.
  - `-c N[kbm]`: first N bytes.
  - `-q`: never print file headers.
  - `-v`: always print file headers.
  - Supports files and stdin (`-` or no file args).

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
