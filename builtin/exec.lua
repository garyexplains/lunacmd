local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

if not ARGC or ARGC == 0 then
    io.stderr:write("exec: missing command\n")
    return
end

local cwd = G_CWD or "."
local parts = {}
for i = 1, ARGC do
    parts[#parts + 1] = sh_quote(ARGS[i] or "")
end

local cmd = "cd " .. sh_quote(cwd) .. " && " .. table.concat(parts, " ")
local ok, why, code = os.execute(cmd)

if not ok then
    if why and code ~= nil then
        io.stderr:write("exec: command failed (" .. tostring(why) .. " " .. tostring(code) .. ")\n")
    else
        io.stderr:write("exec: command failed\n")
    end
end
