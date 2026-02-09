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
- `preview [on|off|status]`
  - Toggles dry-run mode.
  - `preview run <command...>` prints preview plan only (no execution).
  - `preview exec <command...>` prompts for confirmation, then executes once if confirmed.
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
- `jobs`
  - Lists background/stopped jobs.
- `fg %JOB`
  - Brings job to foreground.
- `bg %JOB`
  - Resumes job in background.
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
  - `--lua` emits a Lua table literal with structured entry metadata.
  - with `:||`, `--lua` also sets `LUA_PIPE_OUT` for Lua-table pipeline stages.
  - includes pipeline metadata fields (`__pipe_schema`, `__pipe_default_path`) for generic Lua-table tools.
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
- `wc [-c] [-m] [-l] [-w] [-L] [--lua] [--path PATH] FILE...`
  - Counts bytes/chars/newlines/words/longest-line.
  - Default output is `-l -w -c`.
  - `--lua` emits structured Lua-table output (`results`, optional `total`).
  - In `:||` mode, can consume top-level arrays directly or object input via `--path`.
  - In `:||` mode, if producer provides `__pipe_default_path`, `wc` uses it when `--path` is omitted.
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
  - `--path PATH`: in `:||` mode, select nested array table to truncate (example: `targets[1].entries`).
  - `-q`: never print file headers.
  - `-v`: always print file headers.
  - Supports files and stdin (`-` or no file args).
  - In `:||` mode, can consume top-level array `LUA_PIPE_IN` directly, or object input via `--path`.
  - In `:||` mode, if producer provides `__pipe_default_path`, `head` uses it automatically when `--path` is omitted.
  - In `:||` mode, `-c` is not supported.
- `tail [FILE]...`
  - Prints last 10 lines by default.
  - `-n N[kbm]`: last N lines.
  - `-c N[kbm]`: last N bytes.
  - `-n +N` / `-c +N`: start from the Nth item from the beginning.
  - `--path PATH`: in `:||` mode, select nested array table to trim (example: `targets[1].entries`).
  - `-f`: follow file growth.
  - `-s SECONDS`: poll interval for `-f`.
  - `-q`: never print file headers.
  - `-v`: always print file headers.
  - Supports files and stdin (`-` or no file args).
  - In `:||` mode, can consume top-level array `LUA_PIPE_IN` directly, or object input via `--path`.
  - In `:||` mode, if producer provides `__pipe_default_path`, `tail` uses it automatically when `--path` is omitted.
  - In `:||` mode, `-c` and `-f` are not supported.
- `tojson`
  - Expects a Lua table in `LUA_PIPE_IN` from a `:||` pipeline and prints JSON.
  - `-h` pretty-prints JSON in human-readable form.
  - `--meta` includes full envelope metadata for `pour(...)` input.
  - For `pour(...)` envelopes, default output serializes the payload value (`.value`) instead of envelope internals.
  - `--help` prints usage.
  - Example: `ls --lua /tmp :|| tojson`
- `fromjson [FILE]...`
  - Parses JSON from FILE(s) or stdin into Lua values.
  - In `:||` mode, sets `LUA_PIPE_OUT` to parsed value.
  - For multiple FILEs, outputs an array of parsed values.
  - Example: `fromjson :< /tmp/data.json :|| print(LUA_PIPE_IN.k)`

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
