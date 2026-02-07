local function usage()
    print("usage: tui on|off|status")
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        usage()
        return
    end
end

local sub = ARGS[1]
if not sub or sub == "" or sub == "status" then
    print("tui: " .. ((TUI_MODE and "on") or "off"))
    return
end

if sub == "on" then
    TUI_MODE = true
    return
end

if sub == "off" then
    TUI_MODE = false
    io.write("\027[2J\027[H")
    return
end

io.stderr:write("tui: unknown argument: " .. tostring(sub) .. "\n")
usage()
