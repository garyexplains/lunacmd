local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function parse_count(s)
    local num, suffix = tostring(s or ""):match("^([0-9]+)([kKbBmM]?)$")
    local n = tonumber(num)
    if not n then
        return nil
    end
    if suffix == "k" or suffix == "K" then
        return n * 1024
    end
    if suffix == "b" or suffix == "B" then
        return n * 512
    end
    if suffix == "m" or suffix == "M" then
        return n * 1024 * 1024
    end
    return n
end

local mode = "lines"
local count = 10
local always_header = false
local never_header = false
local files = {}

local i = 1
while i <= (ARGC or 0) do
    local arg = tostring(ARGS[i] or "")
    if arg == "--" then
        i = i + 1
        while i <= ARGC do
            local a = tostring(ARGS[i] or "")
            if a == "-" then
                files[#files + 1] = "-"
            else
                files[#files + 1] = resolve_path(a)
            end
            i = i + 1
        end
        break
    elseif arg == "-h" or arg == "--help" then
        print("usage: head [-n N[kbm]] [-c N[kbm]] [-q] [-v] [FILE]...")
        return
    elseif arg == "-q" then
        never_header = true
    elseif arg == "-v" then
        always_header = true
    elseif arg == "-n" or arg == "-c" then
        if i + 1 > ARGC then
            io.stderr:write("head: option requires an argument -- " .. arg:sub(2) .. "\n")
            return
        end
        local parsed = parse_count(ARGS[i + 1])
        if parsed == nil then
            io.stderr:write("head: invalid number: " .. tostring(ARGS[i + 1]) .. "\n")
            return
        end
        mode = (arg == "-n") and "lines" or "bytes"
        count = parsed
        i = i + 1
    elseif arg:match("^%-n.+") then
        local parsed = parse_count(arg:sub(3))
        if parsed == nil then
            io.stderr:write("head: invalid number: " .. arg:sub(3) .. "\n")
            return
        end
        mode = "lines"
        count = parsed
    elseif arg:match("^%-c.+") then
        local parsed = parse_count(arg:sub(3))
        if parsed == nil then
            io.stderr:write("head: invalid number: " .. arg:sub(3) .. "\n")
            return
        end
        mode = "bytes"
        count = parsed
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("head: unsupported option: " .. arg .. "\n")
        return
    else
        if arg == "-" then
            files[#files + 1] = "-"
        else
            files[#files + 1] = resolve_path(arg)
        end
    end
    i = i + 1
end

if #files == 0 then
    files[1] = "-"
end

local function print_header(label)
    print("==> " .. label .. " <==")
end

local function output_lines(stream, n)
    local printed = 0
    for line in stream:lines() do
        if printed >= n then
            break
        end
        io.write(line, "\n")
        printed = printed + 1
    end
end

local function output_bytes(stream, n)
    if n <= 0 then
        return
    end
    local data = stream:read(n)
    if data and #data > 0 then
        io.write(data)
    end
end

local show_headers = false
if never_header then
    show_headers = false
elseif always_header then
    show_headers = true
else
    show_headers = (#files > 1)
end

for idx, path in ipairs(files) do
    local stream = nil
    local label = path

    if path == "-" then
        stream = io.stdin
        label = "standard input"
    else
        stream = io.open(path, "rb")
        if not stream then
            io.stderr:write("head: cannot open '" .. path .. "'\n")
        end
    end

    if stream then
        if show_headers then
            if idx > 1 then
                io.write("\n")
            end
            print_header(label)
        end

        if mode == "lines" then
            output_lines(stream, count)
        else
            output_bytes(stream, count)
        end

        if stream ~= io.stdin then
            stream:close()
        end
    end
end
