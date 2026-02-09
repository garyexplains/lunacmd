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

local function head_array(arr, n)
    local out = {}
    for idx = 1, math.min(n, #arr) do
        out[#out + 1] = arr[idx]
    end
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

local mode = "lines"
local count = 10
local always_header = false
local never_header = false
local lua_path = nil
local files = {}

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
        print("usage: head [-n N[kbm]] [-c N[kbm]] [-q] [-v] [--path PATH] [FILE]...")
        return
    elseif arg == "--path" then
        if i + 1 > ARGC then
            io.stderr:write("head: option requires an argument -- path\n")
            return
        end
        lua_path = tostring(ARGS[i + 1] or "")
        i = i + 1
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

if LUA_PIPE_ACTIVE and type(LUA_PIPE_IN) == "table" and #files == 1 and files[1] == "-" then
    if mode ~= "lines" then
        io.stderr:write("head: -c is not supported for lua table pipeline input\n")
        return
    end

    local arr = is_array_table(LUA_PIPE_IN)
    local out = nil
    local path_expr = lua_path
    if not path_expr and not arr and type(LUA_PIPE_IN.__pipe_default_path) == "string" then
        path_expr = LUA_PIPE_IN.__pipe_default_path
    end

    if not path_expr and arr then
        out = head_array(LUA_PIPE_IN, count)
    else
        if not path_expr or path_expr == "" then
            io.stderr:write("head: lua table pipeline input must be an array table or use --path PATH\n")
            return
        end
        local tokens, perr = parse_path_expr(path_expr)
        if not tokens then
            io.stderr:write("head: invalid --path: " .. tostring(perr) .. "\n")
            return
        end
        local selected, gerr = get_path_value(LUA_PIPE_IN, tokens)
        if gerr then
            io.stderr:write("head: --path not found: " .. tostring(gerr) .. "\n")
            return
        end
        local selected_arr = is_array_table(selected)
        if not selected_arr then
            io.stderr:write("head: --path must select an array table\n")
            return
        end
        local trimmed = head_array(selected, count)
        out = set_path_value_copy(LUA_PIPE_IN, tokens, trimmed)
        if not out then
            io.stderr:write("head: failed to apply --path\n")
            return
        end
    end

    LUA_PIPE_OUT = out
    if LUA_PIPE_LAST then
        print(to_lua_value(out))
    end
    return
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
