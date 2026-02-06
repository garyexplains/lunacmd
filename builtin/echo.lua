local parts = {}

if ARGC and ARGC > 0 and ARGS then
    for i = 1, ARGC do
        parts[#parts + 1] = tostring(ARGS[i] or "")
    end
end

print(table.concat(parts, " "))
