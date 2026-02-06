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

local function cat_stdin()
    local content = io.read("*a")
    if content then
        io.write(content)
        return true
    end
    io.stderr:write("cat: failed to read stdin\n")
    return false
end

if not ARGC or ARGC == 0 then
    cat_stdin()
    return
end

for i = 1, ARGC do
    local arg = ARGS[i] or ""
    if arg == "-" then
        cat_stdin()
    else
        cat_file(arg)
    end
end
