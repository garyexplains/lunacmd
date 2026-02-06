local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function cat_file(path)
    local resolved = resolve_path(path)
    local f = io.open(resolved, "rb")
    if not f then
        io.stderr:write("cat: cannot open '" .. resolved .. "'\n")
        return false
    end

    local content = f:read("*a")
    f:close()

    if content then
        io.write(content)
        return true
    end

    io.stderr:write("cat: failed to read '" .. resolved .. "'\n")
    return false
end

if not ARGC or ARGC == 0 then
    io.stderr:write("cat: missing file operand\n")
    return
end

for i = 1, ARGC do
    cat_file(ARGS[i] or "")
end
