local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function count_utf8_chars(s)
    local n = utf8.len(s)
    if n then
        return n
    end
    return #s
end

local function longest_line_chars(content)
    local max_len = 0
    local start_idx = 1

    while true do
        local nl = content:find("\n", start_idx, true)
        local line
        if nl then
            line = content:sub(start_idx, nl - 1)
            start_idx = nl + 1
        else
            line = content:sub(start_idx)
        end

        local len = count_utf8_chars(line)
        if len > max_len then
            max_len = len
        end

        if not nl then
            break
        end
    end

    return max_len
end

local function count_newlines(content)
    local n = 0
    for _ in content:gmatch("\n") do
        n = n + 1
    end
    return n
end

local function count_words(content)
    local n = 0
    for _ in content:gmatch("%S+") do
        n = n + 1
    end
    return n
end

local opts = {
    c = false,
    m = false,
    l = false,
    w = false,
    L = false,
}

local files = {}
local parse_options = true

for i = 1, (ARGC or 0) do
    local arg = ARGS[i] or ""
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        print("usage: wc [-c] [-m] [-l] [-w] [-L] [FILE]...")
        return
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        for j = 2, #arg do
            local flag = arg:sub(j, j)
            if opts[flag] == nil then
                io.stderr:write("wc: unsupported option: -" .. flag .. "\n")
                return
            end
            opts[flag] = true
        end
    else
        if arg == "-" then
            files[#files + 1] = "-"
        else
            files[#files + 1] = resolve_path(arg)
        end
    end
end

local any_flag = opts.c or opts.m or opts.l or opts.w or opts.L
if not any_flag then
    opts.l = true
    opts.w = true
    opts.c = true
end

local order = { "l", "w", "m", "c", "L" }
local totals = { c = 0, m = 0, l = 0, w = 0, L = 0 }
local successful = 0

local function print_counts(counts, label)
    local out = {}
    for _, key in ipairs(order) do
        if opts[key] then
            out[#out + 1] = string.format("%8d", counts[key] or 0)
        end
    end
    out[#out + 1] = label
    print(table.concat(out, " "))
end

if #files == 0 then
    local content = io.read("*a") or ""
    local counts = {}
    counts.c = #content
    counts.m = count_utf8_chars(content)
    counts.l = count_newlines(content)
    counts.w = count_words(content)
    counts.L = longest_line_chars(content)
    print_counts(counts, "-")
    return
end

for _, path in ipairs(files) do
    local content = nil

    if path == "-" then
        content = io.read("*a") or ""
    else
        local f = io.open(path, "rb")
        if not f then
            io.stderr:write("wc: cannot open '" .. path .. "'\n")
        else
            content = f:read("*a") or ""
            f:close()
        end
    end

    if content ~= nil then
        local counts = {}
        counts.c = #content
        counts.m = count_utf8_chars(content)
        counts.l = count_newlines(content)
        counts.w = count_words(content)
        counts.L = longest_line_chars(content)

        totals.c = totals.c + counts.c
        totals.m = totals.m + counts.m
        totals.l = totals.l + counts.l
        totals.w = totals.w + counts.w
        if counts.L > totals.L then
            totals.L = counts.L
        end

        print_counts(counts, path)
        successful = successful + 1
    end
end

if successful > 1 then
    print_counts(totals, "total")
end
