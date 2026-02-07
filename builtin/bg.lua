local function usage()
    print("usage: bg %JOB")
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

if type(_JOB_BG) ~= "function" then
    io.stderr:write("bg: runtime support is unavailable\n")
    return
end

local arg = tostring(ARGS[1] or "")
local id = tonumber((arg:gsub("^%%", "")))
if not id then
    io.stderr:write("bg: invalid job id: " .. arg .. "\n")
    return
end

local ok, err = _JOB_BG(id)
if not ok then
    io.stderr:write("bg: " .. tostring(err) .. "\n")
    return
end
