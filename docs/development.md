# Development

## Embedded Lua Version

`lunacmd` currently vendors Lua `5.4.7` in the repository (`lua/` and `lua-5.4.7.tar.gz`).

Most development work does not require manually downloading Lua, because the sources are already present and `make` builds against the vendored tree.

## Updating/Rebuilding Vendored Lua

If you need to refresh the vendored Lua sources:

```sh
curl -L -R -O https://www.lua.org/ftp/lua-5.4.7.tar.gz
tar zxf lua-5.4.7.tar.gz
mv lua-5.4.7 lua
cd lua
make all test
```

Then from repo root:

```sh
make
make test
```

## Notes

- Runtime dependency for local builds: `libreadline-dev`.
- Root `Makefile` builds `lunacmd` and uses `lua/src/liblua.a`.
- On startup, `lunacmd` attempts to load `~/.lunacmd.lua` if present.
- Set `LUNACMD_NO_RC=1` to skip loading `~/.lunacmd.lua` (useful for tests).
- User builtin lookup path is `~/.lunacmd/builtin` (Phase A).
- Set `LUNACMD_NO_USER_BUILTINS=1` to disable user builtin lookup.

## Future Direction

Shipping a vendored Lua version is probably not the best long-term approach. In the future, we plan to replace this with a better automated workflow that fetches and integrates the latest Lua version.
