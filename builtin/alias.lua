local function sorted_keys(t)
    local keys = {}
    for k, _ in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

if type(ALIASES) ~= "table" then
    ALIASES = {}
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: alias [NAME = VALUE...]")
        return
    end
end

if not ARGC or ARGC == 0 then
    for _, k in ipairs(sorted_keys(ALIASES)) do
        print("alias " .. k .. " = " .. tostring(ALIASES[k]))
    end
    return
end

if ARGC == 1 then
    local arg = tostring(ARGS[1] or "")
    local name, value = arg:match("^([^=]+)=(.*)$")
    if name then
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            io.stderr:write("alias: invalid alias name\n")
            return
        end
        ALIASES[name] = value
        return
    end

    if ALIASES[arg] ~= nil then
        print("alias " .. arg .. " = " .. tostring(ALIASES[arg]))
        return
    end

    io.stderr:write("alias: not found: " .. arg .. "\n")
    return
end

local eq_idx = nil
for i = 1, ARGC do
    if ARGS[i] == "=" then
        eq_idx = i
        break
    end
end

if not eq_idx then
    io.stderr:write("alias: expected '='\n")
    return
end

if eq_idx ~= 2 then
    io.stderr:write("alias: usage: alias NAME = VALUE...\n")
    return
end

local name = tostring(ARGS[1] or "")
if name == "" then
    io.stderr:write("alias: invalid alias name\n")
    return
end

if eq_idx == ARGC then
    io.stderr:write("alias: missing alias value\n")
    return
end

local parts = {}
for i = eq_idx + 1, ARGC do
    parts[#parts + 1] = tostring(ARGS[i] or "")
end
ALIASES[name] = table.concat(parts, " ")
