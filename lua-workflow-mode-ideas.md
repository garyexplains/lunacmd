# Lua Workflow Mode Ideas

## Goal

Create a Lua-first workflow mode for quick data tasks with first-class builtins:

- CSV
- JSON
- YAML
- HTTP fetch
- Templating

The design should improve productivity for data pipelines without changing lunacmd's core Lua-first semantics.

## Mode Concept

Use a lightweight mode toggle:

- `workflow on`
- `workflow off`
- `workflow status`

Workflow mode changes defaults and convenience behavior, not parser/language fundamentals.

## Clarified Behavior

### workflow off (default)

- Existing lunacmd behavior.
- Data builtins still work, but users are explicit with flags.
- Conservative/plain output defaults.

### workflow on

Enable data-task-friendly defaults:

1. Structured output defaults
- JSON/CSV/YAML helpers default to structured output suitable for chaining.

2. TTY-aware formatting
- Pretty output when interactive.
- Compact output when piped.

3. Strict parsing defaults
- Fail fast on malformed input unless explicitly lenient.

4. Stdin-first operation
- If no file argument is supplied, read from stdin by default.

5. HTTP defaults tuned for pipelines
- Sensible timeout/retry defaults.
- Body to stdout; metadata via stderr or optional structured envelope.

6. Template convenience
- Templating commands default to reading JSON context from stdin.

7. Optional workflow helpers
- Convenience globals/settings (for example: pretty mode, default timeout).

## What does NOT change

- Lua-first parser and execution model.
- Redirection/pipes syntax.
- Command resolution order.
- Existing builtins unless they opt into workflow defaults.

Workflow mode is a profile of defaults and helpers, not a separate language.

## Proposed First-Class Builtins

- `workflow` (mode/config)
- `json`
- `csv`
- `yaml`
- `http`
- `template`

## Suggested Initial Command Surface

### workflow

- `workflow on`
- `workflow off`
- `workflow status`
- optional future config subcommands

### json

- `json format [FILE|-]`
- `json get PATH [FILE|-]`
- `json set PATH VALUE [FILE|-]`
- `json to-lua [FILE|-]`

### csv

- `csv head [N] [FILE|-]`
- `csv select COLS [FILE|-]`
- `csv filter EXPR [FILE|-]`
- `csv to-json [FILE|-]`

### http

- `http get URL`
- `http post URL :< body.json`
- `http headers URL`

### template

- `template render TEMPLATE_FILE DATA_JSON_FILE`
- `template render-string "Hi {{name}}" :< data.json`

## Implementation Strategy (Phased)

### Phase A (MVP)

- Implement `workflow` toggle/state.
- Implement core `json` and `csv` builtins.
- Add initial `http` support (either backend helper or external bridge).
- Add minimal `template` rendering (`{{path}}`).
- Document in `docs/workflow.md`.
- Add sanity tests for parse/transform/pipe chains.

### Phase B

- Expand YAML support.
- Add richer template features (loops/conditionals).
- Add typed pipeline helpers and richer workflow config.

## Open Questions Captured

1. HTTP backend for first release:
- pure runtime helper vs initial `exec curl` bridge?

2. YAML timing:
- include in MVP or defer to Phase B?

3. Template scope in MVP:
- only `{{path}}` placeholders, or loops/conditionals too?

## Example Workflow

```text
workflow on
http get https://api.example.com/items :| json get data :| csv to-json
```

