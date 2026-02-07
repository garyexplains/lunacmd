local function resolve_path(path)
    path = tostring(path or "")
    if type(_RESOLVE_PATH) == "function" then
        local resolved = _RESOLVE_PATH(path)
        if resolved then
            return resolved
        end
    end
    local base = G_CWD or "."
    local home = os.getenv("HOME")
    if path == "~" and home and home ~= "" then
        return home
    end
    if path:sub(1, 2) == "~/" and home and home ~= "" then
        return home .. path:sub(2)
    end
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: source FILE")
        return
    end
end

if not ARGC or ARGC == 0 then
    io.stderr:write("source: missing file operand\n")
    return
end

if ARGC > 1 then
    io.stderr:write("source: too many arguments\n")
    return
end

local target = ARGS[1]
local resolved = resolve_path(target)
local chunk, load_err = loadfile(resolved)

if not chunk then
    io.stderr:write("source: cannot load '" .. resolved .. "': " .. tostring(load_err) .. "\n")
    return
end

local ok, run_err = pcall(chunk)
if not ok then
    io.stderr:write("source: runtime error in '" .. resolved .. "': " .. tostring(run_err) .. "\n")
end
