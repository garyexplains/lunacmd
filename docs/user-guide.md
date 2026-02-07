# User Guide

This guide is the practical, end-to-end reference for using `lunacmd` day to day.

If you are new, start with `docs/getting-started.md`, then come back here.

## Core Model

`lunacmd` is **Lua-first**:

- Lua syntax should remain valid by default.
- Shell-like behavior is available as a convenience layer.
- Builtins are Lua scripts.
- External OS commands are explicit through `exec`.

Think of it as a programmable Lua CLI that borrows useful shell ergonomics.

## Command Resolution

For a single command word like `foo`:

1. Core builtin (`builtin/foo.lua`)
2. User builtin (`~/.lunacmd/builtin/foo.lua`)
3. Lua fallback (execute line as Lua)

Inspect resolution:

```text
which ls
which mycmd
type ls
type mycmd
```

Disable user builtins:

```sh
LUNACMD_NO_USER_BUILTINS=1 ./lunacmd
```

## Syntax Modes

### Default (Lua-First)

Default mode uses lunacmd operators:

- pipe: `:|`
- stdin: `:<`
- stdout overwrite: `:>`
- stdout append: `:>>`
- stderr overwrite: `2:>`
- stderr append: `2:>>`
- stderr -> stdout: `2:>&1`

Examples:

```text
echo hi :> /tmp/out.txt
cat :< /tmp/out.txt
echo one two :| wc -w
rm /tmp/missing 2:> /tmp/err.log
```

### Legacy Shell Symbols (Opt-In)

Use `:!` when you want classic shell operators:

```text
:! echo hi > /tmp/out.txt
:! cat < /tmp/out.txt
:! echo a | exec grep a
```

Without `:!`, `<`, `>`, and `|` are reserved for Lua-first semantics and parser safety.

## Paths and Tilde Expansion

`~` and `~/...` are resolved against `$HOME` in builtin args and redirection targets.

Examples:

```text
ls ~
cat ~/notes/todo.txt
echo hello :> ~/tmp/out.txt
```

## Special Buffers

Two built-in buffer targets integrate with redirection and stdin:

- `:@mem`: in-memory-style session buffer (file-backed internally, bounded)
- `:@file`: persistent hidden file buffer under `~/.lunacmd/buffer`

Write/read examples:

```text
echo hello :> :@mem
cat :< :@mem

exec ls :> :@file
cat :< :@file
```

Pipe buffer into external command:

```text
cat :< :@mem :| exec grep hello
```

Manage buffers:

```text
lunabuffer status
lunabuffer size 64K
lunabuffer clear mem
lunabuffer clear all
lunabuffer save mem /tmp/mem.bin
```

Notes:

- `cat :< :@mem` does not consume bytes; buffer remains reusable.
- memory buffer has a size limit; writes are truncated to configured max size.

## Pipelines and Data Flow

Pipelines connect stdout of the left command to stdin of the right command.

```text
echo alpha beta :| wc -w
cat :< /etc/hosts :| head -n 5
cat :< :@file :| exec grep lunacmd
```

You can mix builtins and `exec` in a pipeline.

## Background Jobs

Run a command in the background with trailing `&`:

```text
sleep 10s &
```

Manage jobs:

```text
jobs
fg %1
bg %1
```

Behavior:

- `jobs` shows active/stopped jobs.
- `fg %N` brings job to foreground.
- `bg %N` resumes stopped job in background.
- job IDs reset to `%1` when no jobs remain.

## Dry-Run Preview Mode

Use preview mode to inspect what would run, without executing commands.

Commands:

```text
preview on
preview off
preview status
preview run <command...>
preview exec <command...>
```

When preview mode is on, `lunacmd` prints an execution plan and skips execution.

Plan output includes:

- original line
- current working directory
- each command stage and resolved kind
- argv after expansion
- redirections
- pipeline/background markers
- risk label (`safe`, `mutating`, `external`)

Example:

```text
preview on
echo hello :> /tmp/out.txt
preview off
```

`/tmp/out.txt` is not created while preview is on.

### One-Shot Plan Only

Use `preview run` to print a plan for one command without executing it:

```text
preview on
preview run echo once :> /tmp/once.txt
preview status
```

This keeps preview mode set to `on` and does not create `/tmp/once.txt`.

### One-Shot Execute with Confirmation

Use `preview exec` to ask for confirmation, then execute once if approved:

```text
preview on
preview exec echo once :> /tmp/once.txt
```

`lunacmd` shows the plan, prompts `[y/N]`, and executes only when you answer `y`.

## History and Recall

History is stored in `~/.lunacmd/history` and persists across sessions.

Commands:

```text
history
history 20
history -c
history -w
history -r
```

Event recall:

```text
!!
!12
!-3
```

## Aliases

Create command aliases:

```text
alias less = more
alias lstmp = ls /tmp
```

Use passthrough args:

```text
alias ll = ls -l
ll /tmp
```

List aliases:

```text
alias
alias ll
```

## `UTIL` Namespace for Helpers

`UTIL` is a global table intended for reusable one-liners and helper functions.

Example in `~/.lunacmd.lua`:

```lua
function UTIL.trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end
```

Use directly in Lua:

```lua
print(UTIL.trim("  bob  "))
```

Use in command substitution:

```text
ls `UTIL.trim("  /tmp  ")`
echo hi :> `UTIL.trim("  /tmp/x.txt  ")`
```

## Command Substitution (Backticks)

Backticks evaluate a Lua expression and substitute `tostring(result)`.

Example:

```text
echo cwd_is `G_CWD`
```

Rules:

- applies to builtin argument parsing and redirection targets
- expression is evaluated as `return <expr>`
- errors are reported as substitution errors

## Multiline Input

A trailing `\` continues input to the next line.

```text
for i = 1, 3 do \
print(i) \
end
```

Applies to both Lua code and command lines.

## Prompt Customization

Prompt globals:

- `PROMPT`: string/function for normal prompt
- `PROMPT_CONT`: string/function for continuation prompt

Examples:

```lua
PROMPT = "luna> "
PROMPT_CONT = "... "
```

```lua
PROMPT = function()
  return (G_CWD or ".") .. " > "
end
```

Runtime tools:

```text
setprompt LUNA>
setprompt --cont ++
prompt
```

Prompt function context includes:

- `PWD`
- `LAST_STATUS`
- `MODE`
- `TIME`

## TUI Mode

Toggle with:

```text
tui on
tui status
tui off
```

Layout:

- left main area top: files view (multi-column)
- left main area bottom: command/output area
- right side pane: history

Use TUI when you want a visual session view while retaining the same command semantics.

## External Commands with `exec`

Run OS commands explicitly:

```text
exec ls /tmp
exec grep hello /tmp/file.txt
```

When to use `exec`:

- you need an OS tool not implemented as builtin
- you want exact external command semantics

When not to use `exec`:

- you want Lua-first behavior and portability with lunacmd builtins

## Startup File and Session Defaults

`lunacmd` loads `~/.lunacmd.lua` if present.

Typical startup file:

```lua
PROMPT = function()
  return (G_CWD or ".") .. " > "
end

alias("ll", "ls -l")

function UTIL.trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end
```

Skip startup file:

```sh
LUNACMD_NO_RC=1 ./lunacmd
```

## Practical Recipes

### Build a quick report file

```text
echo "Run at: " :> /tmp/report.txt
exec date :>> /tmp/report.txt
ls /tmp :>> /tmp/report.txt
cat /tmp/report.txt
```

### Capture stderr for debugging

```text
rm /path/that/does/not/exist 2:> /tmp/err.log
cat /tmp/err.log
```

### Use buffer as a scratch transport

```text
exec ls /etc :> :@mem
cat :< :@mem :| exec grep conf
```

### Follow logs

```text
tail -f /var/log/syslog
```

### Preview binary bytes

```text
hexdump /bin/ls
hexdump -x /bin/ls
```

## Troubleshooting

### "Parse error: legacy operator ... requires :! prefix"

You used `>`, `<`, or `|` in default mode.

Fix:

- use lunacmd operators (`:>`, `:<`, `:|`), or
- prefix line with `:!` for legacy parsing.

### "Failed to load builtin ..."

Builtin script exists but has load/syntax error.

Check:

- file path
- Lua syntax in builtin file
- command name collision between core/user builtins

### Command behaves as Lua unexpectedly

Use `type <cmd>` and `which <cmd>` to confirm resolution.

If command is `lua-fallback`, you likely expected a builtin or `exec`.

### Prompt function errors

If prompt function throws, lunacmd falls back to safe default prompt and prints a warning.

Fix by testing prompt function in a plain Lua expression first.

## Builtin Coverage

See full builtin reference in `docs/builtins.md`.

## Next Reading

- `docs/language.md` for formal syntax behavior
- `docs/lua-cheatsheet.md` for useful Lua one-liners
- `docs/development.md` for build/runtime internals
- `docs/architecture.md` for parser/execution design
