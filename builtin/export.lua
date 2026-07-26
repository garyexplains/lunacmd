for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: export [NAME=VALUE]...")
        return
    end
end

if not ARGC or ARGC == 0 then
    io.stderr:write("export: missing arguments\n")
    return
end

for i = 1, ARGC do
    local arg = tostring(ARGS[i] or "")
    local eq = arg:find("=")
    if eq then
        local key = arg:sub(1, eq - 1)
        local val = arg:sub(eq + 1)
        if _SETENV then
            _SETENV(key, val)
        else
            io.stderr:write("export: _SETENV not available\n")
            return
        end
    else
        io.stderr:write("export: ignoring '" .. arg .. "' (unsupported without '=')\n")
    end
end
