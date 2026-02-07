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

local function usage()
    print("usage: tail [-f] [-s SECONDS] [-n N[kbm]] [-c N[kbm]] [-q] [-v] [FILE]...")
end

local function parse_count(s)
    local str = tostring(s or "")
    local from_start = false
    local num, suffix

    if str:sub(1, 1) == "+" then
        from_start = true
        str = str:sub(2)
    end

    num, suffix = str:match("^([0-9]+)([kKbBmM]?)$")
    local n = tonumber(num)
    if not n then
        return nil
    end
    if suffix == "k" or suffix == "K" then
        n = n * 1024
    elseif suffix == "b" or suffix == "B" then
        n = n * 512
    elseif suffix == "m" or suffix == "M" then
        n = n * 1024 * 1024
    end
    return n, from_start
end

local function split_lines_keep(content)
    local lines = {}
    local pos = 1
    while pos <= #content do
        local nl = content:find("\n", pos, true)
        if nl then
            lines[#lines + 1] = content:sub(pos, nl)
            pos = nl + 1
        else
            lines[#lines + 1] = content:sub(pos)
            break
        end
    end
    return lines
end

local function tail_lines(content, n, from_start)
    local lines = split_lines_keep(content)
    if n <= 0 then
        return ""
    end
    local start
    if from_start then
        start = n
    else
        start = #lines - n + 1
        if start < 1 then
            start = 1
        end
    end
    if start > #lines then
        return ""
    end
    return table.concat(lines, "", start, #lines)
end

local function tail_bytes(content, n, from_start)
    local len = #content
    if n <= 0 then
        return ""
    end
    if from_start then
        if n > len then
            return ""
        end
        return content:sub(n)
    end
    local start = len - n + 1
    if start < 1 then
        start = 1
    end
    return content:sub(start)
end

local function stat_size(path)
    if type(_STAT) ~= "function" then
        local f = io.open(path, "rb")
        if not f then
            return nil
        end
        local data = f:read("*a") or ""
        f:close()
        return #data
    end
    local st = _STAT(path, true)
    if not st then
        return nil
    end
    return tonumber(st.size) or 0
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local c = f:read("*a") or ""
    f:close()
    return c
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        usage()
        return
    end
end

local mode = "lines"
local count = 10
local from_start = false
local follow = false
local sleep_seconds = 1
local never_header = false
local always_header = false
local files = {}
local i = 1

while i <= (ARGC or 0) do
    local arg = tostring(ARGS[i] or "")
    if arg == "--" then
        i = i + 1
        while i <= ARGC do
            local a = tostring(ARGS[i] or "")
            files[#files + 1] = (a == "-") and "-" or resolve_path(a)
            i = i + 1
        end
        break
    elseif arg == "-f" then
        follow = true
    elseif arg == "-q" then
        never_header = true
    elseif arg == "-v" then
        always_header = true
    elseif arg == "-s" then
        if i + 1 > ARGC then
            io.stderr:write("tail: option requires an argument -- s\n")
            return
        end
        local v = tonumber(ARGS[i + 1])
        if not v or v < 0 then
            io.stderr:write("tail: invalid sleep interval: " .. tostring(ARGS[i + 1]) .. "\n")
            return
        end
        sleep_seconds = v
        i = i + 1
    elseif arg == "-n" or arg == "-c" then
        if i + 1 > ARGC then
            io.stderr:write("tail: option requires an argument -- " .. arg:sub(2) .. "\n")
            return
        end
        local parsed, plus = parse_count(ARGS[i + 1])
        if parsed == nil then
            io.stderr:write("tail: invalid number: " .. tostring(ARGS[i + 1]) .. "\n")
            return
        end
        mode = (arg == "-n") and "lines" or "bytes"
        count = parsed
        from_start = plus
        i = i + 1
    elseif arg:match("^%-n.+") then
        local parsed, plus = parse_count(arg:sub(3))
        if parsed == nil then
            io.stderr:write("tail: invalid number: " .. arg:sub(3) .. "\n")
            return
        end
        mode = "lines"
        count = parsed
        from_start = plus
    elseif arg:match("^%-c.+") then
        local parsed, plus = parse_count(arg:sub(3))
        if parsed == nil then
            io.stderr:write("tail: invalid number: " .. arg:sub(3) .. "\n")
            return
        end
        mode = "bytes"
        count = parsed
        from_start = plus
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("tail: unsupported option: " .. arg .. "\n")
        return
    else
        files[#files + 1] = (arg == "-") and "-" or resolve_path(arg)
    end
    i = i + 1
end

if #files == 0 then
    files[1] = "-"
end

local show_headers
if never_header then
    show_headers = false
elseif always_header then
    show_headers = true
else
    show_headers = (#files > 1)
end

local function print_header(label, first)
    if not first then
        io.write("\n")
    end
    print("==> " .. label .. " <==")
end

local function print_tail(content)
    if mode == "lines" then
        io.write(tail_lines(content, count, from_start))
    else
        io.write(tail_bytes(content, count, from_start))
    end
end

local first_header = true
local follow_files = {}

for _, path in ipairs(files) do
    local label = path
    if path == "-" then
        label = "standard input"
        local content = io.read("*a") or ""
        if show_headers then
            print_header(label, first_header)
            first_header = false
        end
        print_tail(content)
        if follow then
            io.stderr:write("tail: cannot follow standard input\n")
        end
    else
        local content = read_file(path)
        if not content then
            io.stderr:write("tail: cannot open '" .. path .. "'\n")
        else
            if show_headers then
                print_header(label, first_header)
                first_header = false
            end
            print_tail(content)
            if follow then
                follow_files[#follow_files + 1] = { path = path, offset = stat_size(path) or #content }
            end
        end
    end
end

if follow and #follow_files > 0 then
    while true do
        for _, fstate in ipairs(follow_files) do
            local sz = stat_size(fstate.path)
            if sz and sz > fstate.offset then
                local f = io.open(fstate.path, "rb")
                if f then
                    f:seek("set", fstate.offset)
                    local chunk = f:read("*a") or ""
                    f:close()
                    if #chunk > 0 then
                        io.write(chunk)
                    end
                    fstate.offset = sz
                end
            elseif sz and sz < fstate.offset then
                -- File was truncated.
                fstate.offset = sz
            end
        end
        if type(_SLEEP) == "function" then
            _SLEEP(sleep_seconds)
        else
            os.execute("sleep " .. tostring(sleep_seconds))
        end
    end
end
