local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
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
