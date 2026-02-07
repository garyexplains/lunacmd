local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function has_glob_chars(s)
    return s:find("[%*%?%[]") ~= nil
end

local function split_dir_base(path)
    local slash = path:match("^.*()/")
    if slash then
        local dir = path:sub(1, slash - 1)
        if dir == "" then
            dir = "/"
        end
        return dir, path:sub(slash + 1)
    end
    return ".", path
end

local function glob_to_lua_pattern(glob)
    local out = { "^" }
    local i = 1
    while i <= #glob do
        local c = glob:sub(i, i)
        if c == "*" then
            out[#out + 1] = ".*"
        elseif c == "?" then
            out[#out + 1] = "."
        elseif c == "[" then
            local j = glob:find("%]", i + 1, true)
            if j then
                local cls = glob:sub(i + 1, j - 1)
                if cls:sub(1, 1) == "!" then
                    cls = "^" .. cls:sub(2)
                end
                cls = cls:gsub("%%", "%%%%")
                out[#out + 1] = "[" .. cls .. "]"
                i = j
            else
                out[#out + 1] = "%%%["
            end
        elseif c:match("[%(%)%%%.%+%-%^%$]") then
            out[#out + 1] = "%" .. c
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    out[#out + 1] = "$"
    return table.concat(out)
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

local function expand_glob_arg(arg)
    local dir_part, base_glob = split_dir_base(arg)
    local resolved_dir = resolve_path(dir_part)
    local pattern = glob_to_lua_pattern(base_glob)
    local entries = type(_LISTDIR) == "function" and _LISTDIR(resolved_dir) or nil
    local matches = {}

    if not entries then
        return { arg }
    end

    for _, name in ipairs(entries) do
        if name ~= "." and name ~= ".." and name:match(pattern) then
            if dir_part == "." then
                matches[#matches + 1] = name
            elseif dir_part == "/" then
                matches[#matches + 1] = "/" .. name
            else
                matches[#matches + 1] = dir_part .. "/" .. name
            end
        end
    end

    table.sort(matches)
    if #matches == 0 then
        return { arg }
    end
    return matches
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: exec CMD [ARG]...")
        return
    end
end

if not ARGC or ARGC == 0 then
    io.stderr:write("exec: missing command\n")
    return
end

local cwd = G_CWD or "."
local parts = {}
for i = 1, ARGC do
    local arg = tostring(ARGS[i] or "")
    local expanded = {}
    if i == 1 then
        expanded[1] = arg
    elseif has_glob_chars(arg) then
        expanded = expand_glob_arg(arg)
    else
        expanded[1] = arg
    end
    for _, piece in ipairs(expanded) do
        if piece == "~" or piece:sub(1, 2) == "~/" then
            piece = resolve_path(piece)
        end
        parts[#parts + 1] = sh_quote(piece)
    end
end

local cmd = "cd " .. sh_quote(cwd) .. " && " .. table.concat(parts, " ")
local ok, why, code = os.execute(cmd)

if not ok then
    if why and code ~= nil then
        io.stderr:write("exec: command failed (" .. tostring(why) .. " " .. tostring(code) .. ")\n")
    else
        io.stderr:write("exec: command failed\n")
    end
end
