local function usage()
    print("usage: lunabuffer [status]")
    print("       lunabuffer size [N[K|M]]")
    print("       lunabuffer clear [mem|file|all]")
    print("       lunabuffer save <mem|file> FILE")
end

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

local function parse_size_with_units(s)
    local n, unit = tostring(s or ""):match("^([0-9]+)([kKmM]?)$")
    n = tonumber(n)
    if not n then
        return nil
    end
    if unit == "k" or unit == "K" then
        return n * 1024
    end
    if unit == "m" or unit == "M" then
        return n * 1024 * 1024
    end
    return n
end

local function get_status()
    if type(_LUNABUFFER_STATUS) ~= "function" then
        io.stderr:write("lunabuffer: runtime support is unavailable\n")
        return nil
    end
    local info, err = _LUNABUFFER_STATUS()
    if not info then
        io.stderr:write("lunabuffer: " .. tostring(err) .. "\n")
        return nil
    end
    return info
end

local function print_status()
    local info = get_status()
    if not info then
        return
    end
    local mem = info.mem or {}
    local file = info.file or {}
    print(string.format("mem:  %d/%d bytes (%s)", tonumber(mem.size or 0), tonumber(mem.max or 0), tostring(mem.path or "")))
    print(string.format("file: %d bytes (%s)", tonumber(file.size or 0), tostring(file.path or "")))
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        usage()
        return
    end
end

local sub = ARGS[1]

if not sub or sub == "" or sub == "status" then
    print_status()
    return
end

if sub == "size" then
    if ARGC == 1 then
        local info = get_status()
        if not info then
            return
        end
        print(tonumber((info.mem or {}).max or 0))
        return
    end
    if ARGC ~= 2 then
        io.stderr:write("lunabuffer: usage: lunabuffer size [N[K|M]]\n")
        return
    end
    local n = parse_size_with_units(ARGS[2])
    if not n or n < 1 then
        io.stderr:write("lunabuffer: invalid size: " .. tostring(ARGS[2]) .. "\n")
        return
    end
    if type(_LUNABUFFER_SET_SIZE) ~= "function" then
        io.stderr:write("lunabuffer: runtime support is unavailable\n")
        return
    end
    local ok, err = _LUNABUFFER_SET_SIZE(n)
    if not ok then
        io.stderr:write("lunabuffer: " .. tostring(err) .. "\n")
        return
    end
    print_status()
    return
end

if sub == "clear" then
    local kind = ARGS[2] or "all"
    if kind ~= "mem" and kind ~= "file" and kind ~= "all" then
        io.stderr:write("lunabuffer: clear kind must be mem, file, or all\n")
        return
    end
    if type(_LUNABUFFER_CLEAR) ~= "function" then
        io.stderr:write("lunabuffer: runtime support is unavailable\n")
        return
    end
    local ok, err = _LUNABUFFER_CLEAR(kind)
    if not ok then
        io.stderr:write("lunabuffer: " .. tostring(err) .. "\n")
        return
    end
    print_status()
    return
end

if sub == "save" then
    if ARGC ~= 3 then
        io.stderr:write("lunabuffer: usage: lunabuffer save <mem|file> FILE\n")
        return
    end
    local kind = ARGS[2]
    local dst = resolve_path(ARGS[3] or "")
    if kind ~= "mem" and kind ~= "file" then
        io.stderr:write("lunabuffer: save kind must be mem or file\n")
        return
    end
    if type(_LUNABUFFER_SAVE) ~= "function" then
        io.stderr:write("lunabuffer: runtime support is unavailable\n")
        return
    end
    local ok, err = _LUNABUFFER_SAVE(kind, dst)
    if not ok then
        io.stderr:write("lunabuffer: " .. tostring(err) .. "\n")
        return
    end
    print("saved " .. kind .. " buffer to " .. dst)
    return
end

io.stderr:write("lunabuffer: unknown subcommand: " .. tostring(sub) .. "\n")
usage()
