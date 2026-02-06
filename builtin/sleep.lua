if type(_SLEEP) ~= "function" then
    io.stderr:write("sleep: internal sleep function is unavailable\n")
    return
end

if not ARGC or ARGC == 0 then
    io.stderr:write("sleep: missing operand\n")
    return
end

local multipliers = {
    s = 1,
    m = 60,
    h = 3600,
    d = 86400,
}

local total = 0

for i = 1, ARGC do
    local arg = tostring(ARGS[i] or "")
    local num, suffix = arg:match("^([0-9]*%.?[0-9]+)([smhd]?)$")
    if not num then
        io.stderr:write("sleep: invalid time interval '" .. arg .. "'\n")
        return
    end
    local value = tonumber(num)
    if not value then
        io.stderr:write("sleep: invalid time interval '" .. arg .. "'\n")
        return
    end
    local factor = multipliers[suffix] or 1
    total = total + (value * factor)
end

local ok, err = _SLEEP(total)
if not ok then
    io.stderr:write("sleep: " .. tostring(err) .. "\n")
end
