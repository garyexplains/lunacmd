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

local function normalize_path(path)
    local absolute = path:sub(1, 1) == "/"
    local parts = {}

    for part in string.gmatch(path, "[^/]+") do
        if part == "." or part == "" then
            -- Skip.
        elseif part == ".." then
            if #parts > 0 then
                parts[#parts] = nil
            end
        else
            parts[#parts + 1] = part
        end
    end

    local normalized = table.concat(parts, "/")
    if absolute then
        normalized = "/" .. normalized
    end
    if normalized == "" then
        return absolute and "/" or "."
    end
    return normalized
end

local function dirname(path)
    local stripped = path:gsub("/+$", "")
    if stripped == "" or stripped == "/" then
        return "/"
    end
    local parent = stripped:match("^(.*)/[^/]+$")
    if not parent or parent == "" then
        if stripped:sub(1, 1) == "/" then
            return "/"
        end
        return "."
    end
    return parent
end

local function is_dir(path)
    if type(_ISDIR) ~= "function" then
        return false
    end
    local ok = _ISDIR(path)
    return ok == true
end

local function is_empty_dir(path)
    if type(_LISTDIR) ~= "function" then
        return nil, "internal listdir function is unavailable"
    end
    local entries, err = _LISTDIR(path)
    if not entries then
        return nil, err
    end
    for _, name in ipairs(entries) do
        if name ~= "." and name ~= ".." then
            return false
        end
    end
    return true
end

local function remove_one(path)
    if not is_dir(path) then
        io.stderr:write("rmdir: failed to remove '" .. path .. "': Not a directory\n")
        return false
    end

    local empty, err = is_empty_dir(path)
    if empty == nil then
        io.stderr:write("rmdir: failed to remove '" .. path .. "': " .. tostring(err) .. "\n")
        return false
    end
    if not empty then
        io.stderr:write("rmdir: failed to remove '" .. path .. "': Directory not empty\n")
        return false
    end

    local ok, rmerr = os.remove(path)
    if not ok then
        io.stderr:write("rmdir: failed to remove '" .. path .. "': " .. tostring(rmerr) .. "\n")
        return false
    end
    return true
end

local use_parents = false
local paths = {}
local parse_options = true

for i = 1, (ARGC or 0) do
    local arg = ARGS[i] or ""
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        print("usage: rmdir [-p|--parents] DIR...")
        return
    elseif parse_options and (arg == "-p" or arg == "--parents") then
        use_parents = true
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("rmdir: unsupported option: " .. arg .. "\n")
        return
    else
        paths[#paths + 1] = normalize_path(resolve_path(arg))
    end
end

if #paths == 0 then
    io.stderr:write("rmdir: missing operand\n")
    return
end

for _, path in ipairs(paths) do
    if use_parents then
        local cur = path
        while true do
            if not remove_one(cur) then
                break
            end
            local parent = dirname(cur)
            if parent == cur or parent == "." or parent == "/" then
                break
            end
            cur = parent
        end
    else
        remove_one(path)
    end
end
