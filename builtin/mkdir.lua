local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function join_path(a, b)
    if a == "/" then
        return "/" .. b
    end
    if a == "" then
        return b
    end
    return a .. "/" .. b
end

local function mkdir_one(path)
    if type(_MKDIR) ~= "function" then
        io.stderr:write("mkdir: internal mkdir function is unavailable\n")
        return false
    end
    local ok, err = _MKDIR(path)
    if ok then
        return true
    end
    io.stderr:write("mkdir: cannot create directory '" .. path .. "': " .. tostring(err) .. "\n")
    return false
end

local function mkdir_parents(path)
    local absolute = path:sub(1, 1) == "/"
    local current = absolute and "/" or ""

    if path == "/" then
        return true
    end

    for part in path:gmatch("[^/]+") do
        if part ~= "." and part ~= "" then
            if part == ".." then
                -- Keep behavior simple: rely on already-resolved paths.
                current = join_path(current, part)
            else
                current = join_path(current, part)
                if not mkdir_one(current) then
                    return false
                end
            end
        end
    end

    return true
end

local use_parents = false
local paths = {}
local parse_options = true

if not ARGC or ARGC == 0 then
    io.stderr:write("mkdir: missing operand\n")
    return
end

for i = 1, ARGC do
    local arg = ARGS[i] or ""
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        print("usage: mkdir [-p|--parents] DIR...")
        return
    elseif parse_options and arg == "-p" then
        use_parents = true
    elseif parse_options and arg == "--parents" then
        use_parents = true
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("mkdir: unsupported option: " .. arg .. "\n")
        return
    else
        paths[#paths + 1] = resolve_path(arg)
    end
end

if #paths == 0 then
    io.stderr:write("mkdir: missing operand\n")
    return
end

for _, path in ipairs(paths) do
    if use_parents then
        mkdir_parents(path)
    else
        mkdir_one(path)
    end
end
