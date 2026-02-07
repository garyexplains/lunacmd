for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: jobs")
        return
    end
end

if type(_JOBS_LIST) ~= "function" then
    io.stderr:write("jobs: runtime support is unavailable\n")
    return
end

local jobs = _JOBS_LIST() or {}
for i = 1, #jobs do
    local j = jobs[i] or {}
    local id = tonumber(j.id or i) or i
    local st = tostring(j.state or "unknown")
    local cmd = tostring(j.cmd or "")
    print(string.format("[%d] %-7s %s", id, st, cmd))
end
