local function usage()
    print("usage: fromjson [FILE]...")
    print("       fromjson : parse JSON text from FILE(s) or stdin")
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

local files = {}
local parse_options = true
for i = 1, (ARGC or 0) do
    local arg = tostring(ARGS[i] or "")
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        usage()
        return
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("fromjson: unsupported option: " .. arg .. "\n")
        return
    else
        if arg == "-" then
            files[#files + 1] = "-"
        else
            files[#files + 1] = resolve_path(arg)
        end
    end
end

local function parse_json(text)
    local i = 1
    local n = #text

    local function fail(msg)
        error("parse error at byte " .. tostring(i) .. ": " .. msg)
    end

    local function skip_ws()
        while i <= n do
            local c = text:sub(i, i)
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                i = i + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        local out = {}
        if text:sub(i, i) ~= '"' then
            fail('expected \'"\'')
        end
        i = i + 1
        while i <= n do
            local c = text:sub(i, i)
            if c == '"' then
                i = i + 1
                return table.concat(out)
            end
            if c == "\\" then
                i = i + 1
                if i > n then
                    fail("unterminated escape")
                end
                local e = text:sub(i, i)
                if e == '"' or e == "\\" or e == "/" then
                    out[#out + 1] = e
                elseif e == "b" then
                    out[#out + 1] = "\b"
                elseif e == "f" then
                    out[#out + 1] = "\f"
                elseif e == "n" then
                    out[#out + 1] = "\n"
                elseif e == "r" then
                    out[#out + 1] = "\r"
                elseif e == "t" then
                    out[#out + 1] = "\t"
                elseif e == "u" then
                    local hex = text:sub(i + 1, i + 4)
                    if #hex < 4 or not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                        fail("invalid unicode escape")
                    end
                    local cp = tonumber(hex, 16)
                    if utf8 and utf8.char and cp then
                        out[#out + 1] = utf8.char(cp)
                    else
                        out[#out + 1] = "?"
                    end
                    i = i + 4
                else
                    fail("invalid escape \\" .. e)
                end
                i = i + 1
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        fail("unterminated string")
    end

    local function parse_number()
        local start = i
        local c = text:sub(i, i)
        if c == "-" then
            i = i + 1
        end
        if i > n then
            fail("invalid number")
        end
        c = text:sub(i, i)
        if c == "0" then
            i = i + 1
        elseif c:match("%d") then
            while i <= n and text:sub(i, i):match("%d") do
                i = i + 1
            end
        else
            fail("invalid number")
        end
        if i <= n and text:sub(i, i) == "." then
            i = i + 1
            if i > n or not text:sub(i, i):match("%d") then
                fail("invalid number fraction")
            end
            while i <= n and text:sub(i, i):match("%d") do
                i = i + 1
            end
        end
        if i <= n and (text:sub(i, i) == "e" or text:sub(i, i) == "E") then
            i = i + 1
            if i <= n and (text:sub(i, i) == "+" or text:sub(i, i) == "-") then
                i = i + 1
            end
            if i > n or not text:sub(i, i):match("%d") then
                fail("invalid number exponent")
            end
            while i <= n and text:sub(i, i):match("%d") do
                i = i + 1
            end
        end
        local num = tonumber(text:sub(start, i - 1))
        if num == nil then
            fail("invalid number")
        end
        return num
    end

    local function parse_array()
        local arr = {}
        i = i + 1 -- skip '['
        skip_ws()
        if i <= n and text:sub(i, i) == "]" then
            i = i + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parse_value()
            skip_ws()
            if i > n then
                fail("unterminated array")
            end
            local c = text:sub(i, i)
            if c == "]" then
                i = i + 1
                break
            elseif c == "," then
                i = i + 1
                skip_ws()
            else
                fail("expected ',' or ']'")
            end
        end
        return arr
    end

    local function parse_object()
        local obj = {}
        i = i + 1 -- skip '{'
        skip_ws()
        if i <= n and text:sub(i, i) == "}" then
            i = i + 1
            return obj
        end
        while true do
            skip_ws()
            if text:sub(i, i) ~= '"' then
                fail("expected object key string")
            end
            local key = parse_string()
            skip_ws()
            if text:sub(i, i) ~= ":" then
                fail("expected ':' after object key")
            end
            i = i + 1
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            if i > n then
                fail("unterminated object")
            end
            local c = text:sub(i, i)
            if c == "}" then
                i = i + 1
                break
            elseif c == "," then
                i = i + 1
                skip_ws()
            else
                fail("expected ',' or '}'")
            end
        end
        return obj
    end

    parse_value = function()
        skip_ws()
        if i > n then
            fail("unexpected end of input")
        end
        local c = text:sub(i, i)
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "t" and text:sub(i, i + 3) == "true" then
            i = i + 4
            return true
        elseif c == "f" and text:sub(i, i + 4) == "false" then
            i = i + 5
            return false
        elseif c == "n" and text:sub(i, i + 3) == "null" then
            i = i + 4
            return nil
        else
            return parse_number()
        end
    end

    skip_ws()
    local value = parse_value()
    skip_ws()
    if i <= n then
        fail("trailing characters after JSON value")
    end
    return value
end

local function read_input(path)
    if path == "-" then
        return io.read("*a") or ""
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local values = {}
if #files == 0 then
    files[1] = "-"
end

for _, path in ipairs(files) do
    local text = read_input(path)
    if text == nil then
        io.stderr:write("fromjson: cannot open '" .. path .. "'\n")
        return
    end
    local ok, value = pcall(parse_json, text)
    if not ok then
        io.stderr:write("fromjson: " .. tostring(value) .. "\n")
        return
    end
    values[#values + 1] = value
end

local out
if #values == 1 then
    out = values[1]
else
    out = values
end

if LUA_PIPE_ACTIVE then
    LUA_PIPE_OUT = out
    if not LUA_PIPE_LAST then
        return
    end
end

print(to_lua_value(out))
