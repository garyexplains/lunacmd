# Language Model

## Lua-First Semantics

`lunacmd` is designed so Lua syntax remains valid by default.

- Lua expressions like `a < b` and `x > y` are not hijacked as shell operators.
- Builtins are still convenient to call directly (for example `ls`, `cd /tmp`, `cat file.txt`).

## Redirection and Pipes (lunacmd Syntax)

Use these operators in default mode:

- Pipe: `:|`
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
```

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
