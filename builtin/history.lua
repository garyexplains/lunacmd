local function usage()
    print("usage: history [N]")
    print("       history -c")
    print("       history -w")
    print("       history -r")
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        usage()
        return
    end
end

if type(_HISTORY_LIST) ~= "function" then
    io.stderr:write("history: runtime support is unavailable\n")
    return
end

local arg1 = ARGS[1]
if arg1 == "-c" then
    if type(_HISTORY_CLEAR) ~= "function" then
        io.stderr:write("history: clear is unavailable\n")
        return
    end
    _HISTORY_CLEAR()
    if type(_HISTORY_WRITE) == "function" then
        _HISTORY_WRITE()
    end
    return
end

if arg1 == "-w" then
    if type(_HISTORY_WRITE) ~= "function" then
        io.stderr:write("history: write is unavailable\n")
        return
    end
    local ok, err = _HISTORY_WRITE()
    if not ok then
        io.stderr:write("history: " .. tostring(err) .. "\n")
    end
    return
end

if arg1 == "-r" then
    if type(_HISTORY_READ) ~= "function" then
        io.stderr:write("history: read is unavailable\n")
        return
    end
    local ok, err = _HISTORY_READ()
    if not ok then
        io.stderr:write("history: " .. tostring(err) .. "\n")
    end
    return
end

local n = nil
if arg1 and arg1 ~= "" then
    n = tonumber(arg1)
    if not n or n < 0 or math.floor(n) ~= n then
        io.stderr:write("history: invalid count: " .. tostring(arg1) .. "\n")
        return
    end
end

local entries = _HISTORY_LIST() or {}
local start = 1
if n and n > 0 and n < #entries then
    start = #entries - n + 1
end

for i = start, #entries do
    local e = entries[i] or {}
    local id = tonumber(e.id or i) or i
    local line = tostring(e.line or "")
    print(string.format("%5d  %s", id, line))
end
