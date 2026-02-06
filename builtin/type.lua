for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: type CMD...")
        return
    end
end

if not ARGC or ARGC == 0 then
    io.stderr:write("type: missing command operand\n")
    return
end

if type(_RESOLVE_CMD) ~= "function" then
    io.stderr:write("type: internal command resolver is unavailable\n")
    return
end

for i = 1, ARGC do
    local name = tostring(ARGS[i] or "")
    local info = _RESOLVE_CMD(name)
    if info and info.kind == "core-builtin" then
        print(name .. " is a core builtin (" .. tostring(info.path) .. ")")
    elseif info and info.kind == "user-builtin" then
        print(name .. " is a user builtin (" .. tostring(info.path) .. ")")
    elseif info and info.kind == "lua-fallback" then
        print(name .. " is a lua fallback expression")
    else
        print(name .. " is not found")
    end
end
