local use_utc = false
local format = "%c"

if ARGC and ARGC > 0 then
    for i = 1, ARGC do
        local arg = ARGS[i]
        if arg == "-u" then
            use_utc = true
        elseif arg == "-h" or arg == "--help" then
            print("usage: date [-u] [+FORMAT]")
            return
        elseif arg and arg:sub(1, 1) == "+" then
            format = arg:sub(2)
        else
            io.stderr:write("date: unsupported argument: " .. tostring(arg) .. "\n")
            return
        end
    end
end

if use_utc then
    format = "!" .. format
end

print(os.date(format))
