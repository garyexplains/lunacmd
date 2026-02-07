local function resolve_path(path)
    path = tostring(path or "")
    if type(_RESOLVE_PATH) == "function" then
        local resolved = _RESOLVE_PATH(path)
        if resolved then
            return resolved
        end
    end
    local base = G_CWD or "."
    local home = os.getenv("HOME")
    if path == "~" and home and home ~= "" then
        return home
    end
    if path:sub(1, 2) == "~/" and home and home ~= "" then
        return home .. path:sub(2)
    end
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: cat [FILE]...")
        return
    end
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
