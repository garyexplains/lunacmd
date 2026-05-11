# Language Model

## Lua-First Semantics

`lunacmd` is designed so Lua syntax remains valid by default.

- Lua expressions like `a < b` and `x > y` are not hijacked as shell operators.
- Builtins are still convenient to call directly (for example `ls`, `cd /tmp`, `cat file.txt`).

## Redirection and Pipes (lunacmd Syntax)

Use these operators in default mode:

- Pipe: `:|`
- Lua-table pipe: `:||`
- stdin redirection: `:<`
- stdout overwrite: `:>`
- stdout append: `:>>`
- stderr overwrite: `2:>`
- stderr append: `2:>>`
- stderr to stdout: `2:>&1`

Examples:

```text
echo hello :> /tmp/out.txt
echo more :>> /tmp/out.txt
exec cat :< /tmp/out.txt
rm /tmp/missing 2:> /tmp/err.log
rm /tmp/missing :> /tmp/both.log 2:>&1
ls --lua /tmp :|| print(LUA_PIPE_IN.mode)
ls --lua /tmp :|| tojson
ls --lua /tmp :|| head -n 3
ls --lua /tmp :|| tail -n 3
ls --lua /tmp :|| wc -l
ls --lua /tmp :|| wc --lua :|| tojson -h
ls --lua /tmp :|| tojson -h :| more
fromjson :< /tmp/data.json :|| print(LUA_PIPE_IN.k, LUA_PIPE_IN.a[2])
```

You can push an arbitrary Lua value into a `:||` pipeline with `pour(value)`:

```text
t = { ["one key"] = 1, ["two"] = 2 }
pour(t) :|| tojson -h
pour(t) :|| head -n 1
pour(t) :|| tojson -h --meta
```

`pour(value)` normalizes input into a pipe envelope with:
- `value`: original value
- `items`: array view for stream-like builtins
- `__pipe_default_path = "items"` so `head`/`tail` work without `--path`

`tojson` serializes `value` by default for `pour` envelopes. Use `--meta` to include envelope metadata.

Mixed pipelines are supported with a single transition in either direction:
- `:|| ... :|| :| ... :|`
- `:| ... :| :|| ... :||`

### Special Buffer Targets

Two special redirection targets are built in:

- `:@mem` (session memory buffer, default max `16K`)
- `:@file` (`~/.lunacmd/buffer`)

Examples:

```text
echo hello :> :@mem
cat :< :@mem
cat :< :@mem :| exec grep hello
echo persist :> :@file
cat :< :@file
```

## Legacy Shell Symbols (Opt-In)

Legacy symbols are available only when the line starts with `:!`:

```text
:! echo hello > /tmp/out.txt
:! exec cat < /tmp/out.txt
:! echo a | cat
```

Without `:!`, legacy operators produce a parser error with guidance.

## History Recall

History is persisted between sessions and available via:

- `history`
- `history N`
- `history -c`
- `history -w`
- `history -r`

Event recall shortcuts:

- `!!` last command
- `!N` command number `N`
- `!-N` command `N` entries back

## Job Control

Background a command by ending the line with `&`:

```text
sleep 5s &
```

Manage jobs:

- `jobs`
- `fg %JOB`
- `bg %JOB`

Foreground jobs receive terminal signals (for example `Ctrl-C`) without exiting `lunacmd`.

## Dry-Run Preview Mode

Use `preview` to toggle execution preview:

- `preview on`
- `preview off`
- `preview status`
- `preview run <command...>`
- `preview exec <command...>`

When preview mode is on, commands are parsed and shown as an execution plan, but not run.

Use one-shot dry-run without changing mode:

```text
preview run echo hello :> /tmp/out.txt
```

Use one-shot execution with confirmation:

```text
preview exec echo hello :> /tmp/out.txt
```

## Command Substitution (Backticks)

In command mode for builtins (including `exec`), you can embed Lua expressions in backticks:

```text
ls `UTIL.trim("  /tmp  ")`
echo hi :> `UTIL.trim("  /tmp/out.txt  ")`
```

Behavior:

- backtick expressions are evaluated as Lua (`return <expr>`)
- result is converted with `tostring(...)`
- substitution applies to command arguments and redirection targets
- substitution is not applied to plain Lua fallback lines

## TUI Mode

Use the `tui` builtin to toggle the built-in full-screen terminal UI:

- `tui on`
- `tui off`
- `tui status`

Current layout:

- Main area (about 80% width):
  - top: files in current working directory
  - bottom: command input area
- Side area (about 20% width):
  - command history

## User Builtins

`lunacmd` also searches for user-defined builtins in:

- `~/.lunacmd/builtin`

Each command is a Lua file named `<command>.lua`.

Example:

```sh
mkdir -p ~/.lunacmd/builtin
cat > ~/.lunacmd/builtin/hi.lua <<'EOF'
print("hello from user builtin")
EOF
```

Then in `lunacmd`:

```text
hi
```

Resolution order is:

1. core builtin (`builtin/<cmd>.lua` in project)
2. user builtin (`~/.lunacmd/builtin/<cmd>.lua`)
3. Lua fallback expression

Disable user builtin lookup with:

```sh
LUNACMD_NO_USER_BUILTINS=1 ./lunacmd
```

## Lua Helper Namespace (`UTIL`)

`lunacmd` initializes a global `UTIL` table at startup so you can store reusable helper functions.

Example `~/.lunacmd.lua`:

```lua
function UTIL.trim(s)
  return (tostring(s):gsub("^%s+",""):gsub("%s+$",""))
end
```

Then in `lunacmd`:

```lua
print(UTIL.trim("  bob  "))
```

## Aliases

Aliases are stored in `ALIASES` and expanded before command resolution.

Shell-style examples:

```text
alias less = more
alias lstmp = ls /tmp
```

Argument passthrough works:

```text
alias ll = ls -l
ll /tmp
```

Lua config (`~/.lunacmd.lua`) can define aliases directly:

```lua
alias("less", "more")
alias("lstmp", "ls /tmp")
```

## Multiline Input

A trailing backslash `\` continues to the next line:

```text
for i = 1, 3 do \
print(i) \
end
```

## User-Defined Prompt

`lunacmd` supports prompt customization through Lua globals:

- `PROMPT` (string or function)
- `PROMPT_CONT` (string or function)

Default values on a fresh install:

- `PROMPT = "luna> "`
- `PROMPT_CONT = "... "`

Examples:

```lua
PROMPT = "luna> "
PROMPT_CONT = "... "
```

```lua
PROMPT = function()
  return (G_CWD or ".") .. " $ "
end
```

Prompt functions can use:

- `PWD`
- `LAST_STATUS`
- `MODE`
- `TIME` (Unix timestamp)

Startup config can be placed in `~/.lunacmd.lua`.

### Quick Examples

Static prompt:

```lua
PROMPT = "luna> "
```

Dynamic prompt with cwd:

```lua
PROMPT = function()
  return (G_CWD or ".") .. " > "
end
```

Show command status in prompt:

```lua
PROMPT = function()
  return "[" .. tostring(LAST_STATUS or 0) .. "] " .. (G_CWD or ".") .. " > "
end
```

Custom continuation prompt for multiline input:

```lua
PROMPT_CONT = "++ "
```

### Runtime Updates

You can change prompts live:

```text
setprompt LUNA>
setprompt --cont ++
prompt
```

Or directly with Lua:

```lua
PROMPT = "dev> "
PROMPT_CONT = "... "
```

### Persistent Prompt Configuration

Put prompt definitions in `~/.lunacmd.lua`, for example:

```lua
PROMPT = function()
  return (G_CWD or ".") .. " $ "
end

PROMPT_CONT = "... "
```

`lunacmd` loads this file at startup. Set `LUNACMD_NO_RC=1` to skip loading it.

## Current Execution Scope

- Single-command execution is implemented.
- Redirection is implemented.
- Pipeline execution is implemented.
