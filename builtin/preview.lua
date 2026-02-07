local function usage()
    print("usage: preview [on|off|status]")
    print("       preview run <command...>")
    print("       preview exec <command...>")
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        usage()
        return
    end
end

local function get_mode()
    if type(_PREVIEW_GET) == "function" then
        return _PREVIEW_GET() and true or false
    end
    return PREVIEW_MODE and true or false
end

local function set_mode(v)
    if type(_PREVIEW_SET) == "function" then
        _PREVIEW_SET(v and true or false)
    else
        PREVIEW_MODE = v and true or false
    end
end

if not ARGC or ARGC == 0 then
    print("preview: " .. (get_mode() and "on" or "off"))
    return
end

local cmd = tostring(ARGS[1] or "")
if cmd == "status" then
    print("preview: " .. (get_mode() and "on" or "off"))
    return
end

if cmd == "on" then
    set_mode(true)
    print("preview: on")
    return
end

if cmd == "off" then
    set_mode(false)
    print("preview: off")
    return
end

if cmd == "run" then
    io.stderr:write("preview: usage: preview run <command...>\n")
    return
end

if cmd == "exec" then
    io.stderr:write("preview: usage: preview exec <command...>\n")
    return
end

io.stderr:write("preview: unknown command: " .. cmd .. "\n")
usage()
