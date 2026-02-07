# Lunacmd Brainstorming

1. Add job control: background tasks (`&`), `jobs`, `fg`, `bg`, and signal handling.
2. Implement command substitution for Lua-first syntax (e.g. capture output into Lua variables cleanly).
3. Add structured pipelines (text + table/JSON modes) so commands can pass typed data, not just bytes.
4. Build a plugin registry for user builtins with metadata (`name`, `version`, `help`, `deps`) and enable/disable controls.
5. Add filesystem watch hooks (`watch PATH do ... end`) for reactive scripts.
6. Add session state persistence (`history`, aliases, prompt, buffer settings, last cwd) with profiles.
7. Expand `exec` with safer modes: timeout, resource limits, and explicit env overrides.
8. Add a pure-Lua `find` builtin with predicates and Lua filter expressions.
9. Add a package-like `lunacmd install` for community builtins under `~/.lunacmd/builtin`.
10. Create a “Lua workflow mode” with helpers for quick data tasks (CSV/JSON/YAML parsing, HTTP fetch, templating) as first-class builtins.
