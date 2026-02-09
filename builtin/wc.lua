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

local function is_array_table(t)
    if type(t) ~= "table" then
        return false, 0
    end
    local n = #t
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > n then
            return false, 0
        end
        count = count + 1
    end
    if count ~= n then
        return false, 0
    end
    return true, n
end

local function to_lua_value(v, indent)
    indent = indent or ""
    local tv = type(v)
    if tv == "nil" then
        return "nil"
    elseif tv == "boolean" or tv == "number" then
        return tostring(v)
    elseif tv == "string" then
        return string.format("%q", v)
    elseif tv == "table" then
        local arr, n = is_array_table(v)
        local parts = {}
        local next_indent = indent .. "  "
        if arr then
            for i = 1, n do
                parts[#parts + 1] = next_indent .. to_lua_value(v[i], next_indent)
            end
            if #parts == 0 then
                return "{}"
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        end
        local keys = {}
        for k, _ in pairs(v) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for _, ks in ipairs(keys) do
            parts[#parts + 1] = next_indent .. "[" .. string.format("%q", ks) .. "] = " .. to_lua_value(v[ks], next_indent)
        end
        if #parts == 0 then
            return "{}"
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return string.format("%q", tostring(v))
end

local function parse_path_expr(expr)
    local s = tostring(expr or "")
    local len = #s
    local pos = 1
    local tokens = {}

    if len == 0 then
        return nil, "empty path"
    end

    while pos <= len do
        local ch = s:sub(pos, pos)
        if ch == "." then
            pos = pos + 1
            if pos > len then
                return nil, "trailing '.' in path"
            end
            ch = s:sub(pos, pos)
        end

        if ch == "[" then
            local close = s:find("]", pos, true)
            if not close then
                return nil, "missing ']' in path"
            end
            local inside = s:sub(pos + 1, close - 1)
            local idx = tonumber(inside)
            if not idx or idx < 1 or idx % 1 ~= 0 then
                return nil, "invalid array index in path"
            end
            tokens[#tokens + 1] = { kind = "index", value = idx }
            pos = close + 1
        else
            local ident = s:match("^([%a_][%w_]*)", pos)
            if not ident then
                return nil, "invalid identifier in path"
            end
            tokens[#tokens + 1] = { kind = "key", value = ident }
            pos = pos + #ident
        end
    end

    return tokens
end

local function token_label(tok)
    if tok.kind == "index" then
        return "[" .. tostring(tok.value) .. "]"
    end
    return tostring(tok.value)
end

local function get_path_value(root, tokens)
    local cur = root
    for ti = 1, #tokens do
        local tok = tokens[ti]
        if type(cur) ~= "table" then
            return nil, "path component '" .. token_label(tok) .. "' parent is not a table"
        end
        cur = cur[tok.value]
        if cur == nil then
            return nil, "path component '" .. token_label(tok) .. "' not found"
        end
    end
    return cur
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
    lua = false,
}

local files = {}
local parse_options = true
local lua_path = nil
local i = 1

while i <= (ARGC or 0) do
    local arg = ARGS[i] or ""
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        print("usage: wc [-c] [-m] [-l] [-w] [-L] [--lua] [--path PATH] [FILE]...")
        return
    elseif parse_options and arg == "--lua" then
        opts.lua = true
    elseif parse_options and arg == "--path" then
        local nxt = ARGS[i + 1]
        if nxt == nil then
            io.stderr:write("wc: option requires an argument -- path\n")
            return
        end
        lua_path = tostring(nxt)
        i = i + 1
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
    i = i + 1
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
local results = {}

local function add_result_row(counts, label, source, selected_path)
    results[#results + 1] = {
        label = label,
        source = source,
        path = selected_path,
        c = counts.c,
        m = counts.m,
        l = counts.l,
        w = counts.w,
        L = counts.L,
    }
end

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

local function compute_counts_from_content(content)
    local counts = {}
    counts.c = #content
    counts.m = count_utf8_chars(content)
    counts.l = count_newlines(content)
    counts.w = count_words(content)
    counts.L = longest_line_chars(content)
    return counts
end

local function build_lua_output()
    local out = {
        mode = "lua",
        __pipe_schema = "object",
        __pipe_default_path = "results",
        options = {
            c = opts.c,
            m = opts.m,
            l = opts.l,
            w = opts.w,
            L = opts.L,
        },
        results = results,
    }
    if successful > 1 then
        out.total = {
            c = totals.c,
            m = totals.m,
            l = totals.l,
            w = totals.w,
            L = totals.L,
        }
    end
    return out
end

if LUA_PIPE_ACTIVE and type(LUA_PIPE_IN) == "table" and #files == 0 then
    local selected = LUA_PIPE_IN
    local selected_path = "(root)"
    local arr = is_array_table(selected)

    if not arr then
        local path_expr = lua_path
        if (not path_expr or path_expr == "") and type(LUA_PIPE_IN.__pipe_default_path) == "string" then
            path_expr = LUA_PIPE_IN.__pipe_default_path
        end
        if not path_expr or path_expr == "" then
            io.stderr:write("wc: lua table pipeline input must be an array table or use --path PATH\n")
            return
        end
        local tokens, perr = parse_path_expr(path_expr)
        if not tokens then
            io.stderr:write("wc: invalid --path: " .. tostring(perr) .. "\n")
            return
        end
        local value, gerr = get_path_value(LUA_PIPE_IN, tokens)
        if gerr then
            io.stderr:write("wc: --path not found: " .. tostring(gerr) .. "\n")
            return
        end
        local is_arr = is_array_table(value)
        if not is_arr then
            io.stderr:write("wc: --path must select an array table\n")
            return
        end
        selected = value
        selected_path = path_expr
    end

    local lines = {}
    for i = 1, #selected do
        lines[#lines + 1] = tostring(selected[i])
    end
    local content = table.concat(lines, "\n")
    if #selected > 0 then
        content = content .. "\n"
    end

    local counts = compute_counts_from_content(content)
    add_result_row(counts, "lua-pipe", "lua-pipe", selected_path)
    totals.c = counts.c
    totals.m = counts.m
    totals.l = counts.l
    totals.w = counts.w
    totals.L = counts.L
    successful = 1

    if opts.lua then
        local out = build_lua_output()
        LUA_PIPE_OUT = out
        if LUA_PIPE_LAST then
            print(to_lua_value(out))
        end
    else
        print_counts(counts, "lua-pipe")
    end
    return
end

if #files == 0 then
    local content = io.read("*a") or ""
    local counts = compute_counts_from_content(content)
    add_result_row(counts, "-", "stdin", nil)
    totals.c = counts.c
    totals.m = counts.m
    totals.l = counts.l
    totals.w = counts.w
    totals.L = counts.L
    successful = 1
    if opts.lua then
        local out = build_lua_output()
        if LUA_PIPE_ACTIVE then
            LUA_PIPE_OUT = out
            if not LUA_PIPE_LAST then
                return
            end
        end
        print(to_lua_value(out))
    else
        print_counts(counts, "-")
    end
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
        local counts = compute_counts_from_content(content)

        totals.c = totals.c + counts.c
        totals.m = totals.m + counts.m
        totals.l = totals.l + counts.l
        totals.w = totals.w + counts.w
        if counts.L > totals.L then
            totals.L = counts.L
        end

        add_result_row(counts, path, "file", path)
        if not opts.lua then
            print_counts(counts, path)
        end
        successful = successful + 1
    end
end

if opts.lua then
    local out = build_lua_output()
    if LUA_PIPE_ACTIVE then
        LUA_PIPE_OUT = out
        if not LUA_PIPE_LAST then
            return
        end
    end
    print(to_lua_value(out))
    return
end

if successful > 1 then
    print_counts(totals, "total")
end
