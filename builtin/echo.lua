for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: echo [ARG]...")
        return
    end
end

local parts = {}

if ARGC and ARGC > 0 and ARGS then
    for i = 1, ARGC do
        parts[#parts + 1] = tostring(ARGS[i] or "")
    end
end

print(table.concat(parts, " "))
