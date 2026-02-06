local function normalize_path(path)
    local absolute = path:sub(1, 1) == "/"
    local parts = {}

    for part in string.gmatch(path, "[^/]+") do
        if part == "." or part == "" then
            -- Skip.
        elseif part == ".." then
            if #parts > 0 then
                parts[#parts] = nil
            end
        else
            parts[#parts + 1] = part
        end
    end

    local normalized = table.concat(parts, "/")
    if absolute then
        normalized = "/" .. normalized
    end

    if normalized == "" then
        if absolute then
            return "/"
        end
        return "."
    end

    return normalized
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: cd [DIR]")
        return
    end
end

local base = G_CWD or "."
local target = ARGS and ARGS[1] or nil

if ARGC and ARGC > 1 then
    print("cd: too many arguments")
    return
end

if not target or target == "" then
    target = os.getenv("HOME") or base
elseif target:sub(1, 1) ~= "/" then
    target = base .. "/" .. target
end

target = normalize_path(target)

if type(_LISTDIR) ~= "function" then
    print("cd: internal listdir function is unavailable")
    return
end

local entries, _ = _LISTDIR(target)
if not entries then
    print("cd: no such file or directory: " .. (ARGS and ARGS[1] or target))
    return
end

G_CWD = target
