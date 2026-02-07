local function usage()
    print("usage: fg %JOB")
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        usage()
        return
    end
end

if (ARGC or 0) < 1 then
    usage()
    return
end

if type(_JOB_FG) ~= "function" then
    io.stderr:write("fg: runtime support is unavailable\n")
    return
end

local arg = tostring(ARGS[1] or "")
local id = tonumber((arg:gsub("^%%", "")))
if not id then
    io.stderr:write("fg: invalid job id: " .. arg .. "\n")
    return
end

local ok, status_or_err = _JOB_FG(id)
if not ok then
    io.stderr:write("fg: " .. tostring(status_or_err) .. "\n")
    return
end
