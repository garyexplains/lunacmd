if not ARGC or ARGC == 0 then
    io.stderr:write("which: missing command operand\n")
    return
end

if type(_RESOLVE_CMD) ~= "function" then
    io.stderr:write("which: internal command resolver is unavailable\n")
    return
end

for i = 1, ARGC do
    local name = tostring(ARGS[i] or "")
    local info = _RESOLVE_CMD(name)
    if info and info.path then
        print(info.path)
    elseif info and info.kind == "lua-fallback" then
        print(name .. ": lua-fallback")
    else
        print(name .. ": not found")
    end
end
