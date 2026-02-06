local base = G_CWD or "."
local dirname = ARGS and ARGS[1] or nil

if dirname and dirname ~= "" then
    if dirname:sub(1, 1) ~= "/" then
        dirname = base .. "/" .. dirname
    end
else
    dirname = base
end

if type(_LISTDIR) ~= "function" then
    print("ls: internal listdir function is unavailable")
    return
end

local entries, _ = _LISTDIR(dirname)
if not entries then
    print("ls: cannot access '" .. dirname .. "'")
    return
end

table.sort(entries)
for _, name in ipairs(entries) do
    print(name)
end
