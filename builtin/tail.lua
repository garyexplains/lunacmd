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
    print("usage: tail [-f] [-s SECONDS] [-n N[kbm]] [-c N[kbm]] [-q] [-v] [--path PATH] [FILE]...")
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

local function shallow_copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
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

local function set_path_value_copy(root, tokens, new_value)
    if #tokens == 0 then
        return new_value
    end
    if type(root) ~= "table" then
        return nil, "path root is not a table"
    end

    local out = shallow_copy_table(root)
    local in_cursor = root
    local out_cursor = out

    for ti = 1, #tokens - 1 do
        local tok = tokens[ti]
        local next_in = in_cursor[tok.value]
        if type(next_in) ~= "table" then
            return nil, "path component '" .. token_label(tok) .. "' is not a table"
        end
        local next_out = shallow_copy_table(next_in)
        out_cursor[tok.value] = next_out
        in_cursor = next_in
        out_cursor = next_out
    end

    out_cursor[tokens[#tokens].value] = new_value
    return out
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

local function tail_array(arr, n, plus)
    local len = #arr
    if n <= 0 then
        return {}
    end
    local start
    if plus then
        start = n
    else
        start = len - n + 1
        if start < 1 then
            start = 1
        end
    end
    if start > len then
        return {}
    end
    local out = {}
    for i = start, len do
        out[#out + 1] = arr[i]
    end
    return out
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
local lua_path = nil
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
    elseif arg == "--path" then
        if i + 1 > ARGC then
            io.stderr:write("tail: option requires an argument -- path\n")
            return
        end
        lua_path = tostring(ARGS[i + 1] or "")
        i = i + 1
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

if LUA_PIPE_ACTIVE and type(LUA_PIPE_IN) == "table" and #files == 1 and files[1] == "-" then
    if follow then
        io.stderr:write("tail: -f is not supported for lua table pipeline input\n")
        return
    end
    if mode ~= "lines" then
        io.stderr:write("tail: -c is not supported for lua table pipeline input\n")
        return
    end

    local arr = is_array_table(LUA_PIPE_IN)
    local out = nil
    local path_expr = lua_path
    if not path_expr and not arr and type(LUA_PIPE_IN.__pipe_default_path) == "string" then
        path_expr = LUA_PIPE_IN.__pipe_default_path
    end

    if not path_expr and arr then
        out = tail_array(LUA_PIPE_IN, count, from_start)
    else
        if not path_expr or path_expr == "" then
            io.stderr:write("tail: lua table pipeline input must be an array table or use --path PATH\n")
            return
        end
        local tokens, perr = parse_path_expr(path_expr)
        if not tokens then
            io.stderr:write("tail: invalid --path: " .. tostring(perr) .. "\n")
            return
        end
        local selected, gerr = get_path_value(LUA_PIPE_IN, tokens)
        if gerr then
            io.stderr:write("tail: --path not found: " .. tostring(gerr) .. "\n")
            return
        end
        local selected_arr = is_array_table(selected)
        if not selected_arr then
            io.stderr:write("tail: --path must select an array table\n")
            return
        end
        local trimmed = tail_array(selected, count, from_start)
        out = set_path_value_copy(LUA_PIPE_IN, tokens, trimmed)
        if not out then
            io.stderr:write("tail: failed to apply --path\n")
            return
        end
    end

    LUA_PIPE_OUT = out
    if LUA_PIPE_LAST then
        print(to_lua_value(out))
    end
    return
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
