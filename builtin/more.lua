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

local function read_lines_from_stream(stream)
    local lines = {}
    for line in stream:lines() do
        lines[#lines + 1] = line
    end
    return lines
end

local function read_lines_from_file(path)
    local resolved = resolve_path(path)
    local f = io.open(resolved, "rb")
    if not f then
        io.stderr:write("more: cannot open '" .. resolved .. "'\n")
        return nil
    end
    local lines = read_lines_from_stream(f)
    f:close()
    return lines, resolved
end

local function print_all(lines, header)
    if header then
        print("==> " .. header .. " <==")
    end
    for _, line in ipairs(lines) do
        print(line)
    end
end

local function find_next(lines, pattern, start_idx)
    local i
    if not pattern or pattern == "" then
        return nil
    end
    for i = start_idx, #lines do
        if lines[i]:find(pattern) then
            return i
        end
    end
    return nil
end

local function tty_readline(tty_out)
    local chars = {}
    while true do
        local ch, err = _GETCH()
        if not ch then
            return nil, err
        end
        if ch == "\n" or ch == "\r" then
            tty_out:write("\n")
            tty_out:flush()
            return table.concat(chars)
        end
        if ch == "\127" or ch == "\b" then
            if #chars > 0 then
                chars[#chars] = nil
                tty_out:write("\b \b")
                tty_out:flush()
            end
        else
            chars[#chars + 1] = ch
            tty_out:write(ch)
            tty_out:flush()
        end
    end
end

local function page_lines(lines, tty_out, header)
    local rows = tonumber(os.getenv("LINES") or "") or 24
    local page_size = rows - 1
    local idx = 1
    local search_pat = nil

    if page_size < 1 then
        page_size = 1
    end

    local function show(count)
        local shown = 0
        while idx <= #lines and shown < count do
            io.write(lines[idx], "\n")
            idx = idx + 1
            shown = shown + 1
        end
    end

    if header then
        io.write("==> ", header, " <==\n")
    end

    show(page_size)
    while idx <= #lines do
        tty_out:write("--More-- (space:page enter:line b:back /:search n:next q:quit) ")
        tty_out:flush()

        local key = _GETCH()
        tty_out:write("\r\27[2K")
        tty_out:flush()

        if not key then
            return
        elseif key == "q" then
            return
        elseif key == " " then
            show(page_size)
        elseif key == "\n" or key == "\r" then
            show(1)
        elseif key == "b" then
            idx = math.max(1, idx - (2 * page_size))
            show(page_size)
        elseif key == "/" then
            tty_out:write("/")
            tty_out:flush()
            local pat = tty_readline(tty_out) or ""
            search_pat = pat
            local next_idx = find_next(lines, search_pat, idx)
            if next_idx then
                idx = next_idx
                show(page_size)
            else
                tty_out:write("Pattern not found: ", search_pat, "\n")
                tty_out:flush()
            end
        elseif key == "n" then
            local next_idx = find_next(lines, search_pat, idx)
            if next_idx then
                idx = next_idx
                show(page_size)
            else
                tty_out:write("Pattern not found\n")
                tty_out:flush()
            end
        end
    end
end

local sources = {}
local i

for i = 1, (ARGC or 0) do
    local arg = ARGS[i] or ""
    if arg == "-h" or arg == "--help" then
        print("usage: more [FILE]...")
        return
    elseif arg == "-" then
        sources[#sources + 1] = { kind = "stdin", label = "-" }
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("more: unsupported option: " .. arg .. "\n")
        return
    else
        sources[#sources + 1] = { kind = "file", path = arg }
    end
end

if #sources == 0 then
    sources[1] = { kind = "stdin", label = "-" }
end

local tty_out = io.open("/dev/tty", "w")
local interactive = tty_out and (type(_GETCH) == "function")
local multiple = #sources > 1

for _, src in ipairs(sources) do
    local lines = nil
    local header = nil

    if src.kind == "stdin" then
        lines = read_lines_from_stream(io.stdin)
        header = src.label
    else
        local resolved
        lines, resolved = read_lines_from_file(src.path)
        header = resolved
    end

        if lines then
            if interactive then
                page_lines(lines, tty_out, multiple and header or nil)
            else
                print_all(lines, multiple and header or nil)
            end
        end
end

if tty_out then
    tty_out:close()
end
