local function usage()
    print("usage: tojson [-h] [--meta]")
    print("       tojson : expects LUA_PIPE_IN from a :|| pipeline")
    print("  -h      pretty-print JSON (human readable)")
    print("  --meta  include full envelope metadata (for pour envelopes)")
end

local pretty = false
local show_meta = false

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "--help" then
        usage()
        return
    elseif a == "-h" then
        pretty = true
    elseif a == "--meta" then
        show_meta = true
    else
        io.stderr:write("tojson: unsupported option: " .. tostring(a) .. "\n")
        usage()
        return
    end
end

if not LUA_PIPE_ACTIVE then
    io.stderr:write("tojson: this command is intended for :|| pipelines\n")
    return
end

if type(LUA_PIPE_IN) ~= "table" then
    io.stderr:write("tojson: expected table input from LUA_PIPE_IN\n")
    return
end

local source = LUA_PIPE_IN
if not show_meta
    and type(LUA_PIPE_IN.__pipe_origin) == "string"
    and LUA_PIPE_IN.__pipe_origin == "pour"
    and LUA_PIPE_IN.value ~= nil then
    source = LUA_PIPE_IN.value
end

local function is_array(t)
    local n = #t
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false, 0
        end
        if k > n then
            return false, 0
        end
        count = count + 1
    end
    if count ~= n then
        return false, 0
    end
    return true, n
end

local function json_escape(s)
    local out = {}
    local i = 1
    local len = #s
    while i <= len do
        local c = s:sub(i, i)
        local b = string.byte(c)
        if c == '"' then
            out[#out + 1] = '\\"'
        elseif c == "\\" then
            out[#out + 1] = "\\\\"
        elseif c == "\b" then
            out[#out + 1] = "\\b"
        elseif c == "\f" then
            out[#out + 1] = "\\f"
        elseif c == "\n" then
            out[#out + 1] = "\\n"
        elseif c == "\r" then
            out[#out + 1] = "\\r"
        elseif c == "\t" then
            out[#out + 1] = "\\t"
        elseif b and b < 32 then
            out[#out + 1] = string.format("\\u%04x", b)
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

local function encode(v, seen, depth)
    depth = depth or 0
    local indent = string.rep("  ", depth)
    local child_indent = string.rep("  ", depth + 1)
    local tv = type(v)
    if tv == "nil" then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("cannot encode non-finite number")
        end
        return tostring(v)
    elseif tv == "string" then
        return '"' .. json_escape(v) .. '"'
    elseif tv == "table" then
        local parts = {}
        if seen[v] then
            error("cannot encode recursive table")
        end
        seen[v] = true

        local arr, n = is_array(v)
        if arr then
            for i = 1, n do
                if pretty then
                    parts[#parts + 1] = child_indent .. encode(v[i], seen, depth + 1)
                else
                    parts[#parts + 1] = encode(v[i], seen, depth + 1)
                end
            end
            seen[v] = nil
            if #parts == 0 then
                return "[]"
            end
            if pretty then
                return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        local keys = {}
        for k, _ in pairs(v) do
            if type(k) ~= "string" then
                seen[v] = nil
                error("object keys must be strings")
            end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if pretty then
                parts[#parts + 1] = child_indent .. '"' .. json_escape(k) .. '": ' .. encode(v[k], seen, depth + 1)
            else
                parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. encode(v[k], seen, depth + 1)
            end
        end
        seen[v] = nil
        if #parts == 0 then
            return "{}"
        end
        if pretty then
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    error("unsupported type: " .. tv)
end

local ok, encoded = pcall(encode, source, {}, 0)
if not ok then
    io.stderr:write("tojson: " .. tostring(encoded) .. "\n")
    return
end

print(encoded)
