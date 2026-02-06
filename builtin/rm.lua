local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function is_dir(path)
    if type(_ISDIR) ~= "function" then
        return false
    end
    local ok = _ISDIR(path)
    return ok == true
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return is_dir(path)
end

local function prompt_remove(path)
    io.write("rm: remove '" .. path .. "'? ")
    io.flush()
    local answer = io.read("*l")
    if not answer then
        return false
    end
    return answer:match("^[Yy]") ~= nil
end

local opts = {
    interactive = false,
    force = false,
}

local paths = {}
local parse_options = true

for i = 1, (ARGC or 0) do
    local arg = ARGS[i] or ""
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        print("usage: rm [-f|--force] [-i|--interactive] FILE...")
        return
    elseif parse_options and arg == "-i" then
        opts.interactive = true
        opts.force = false
    elseif parse_options and arg == "--interactive" then
        opts.interactive = true
        opts.force = false
    elseif parse_options and arg == "-f" then
        opts.force = true
        opts.interactive = false
    elseif parse_options and arg == "--force" then
        opts.force = true
        opts.interactive = false
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("rm: unsupported option: " .. arg .. "\n")
        return
    else
        paths[#paths + 1] = resolve_path(arg)
    end
end

if #paths == 0 then
    if not opts.force then
        io.stderr:write("rm: missing operand\n")
    end
    return
end

for _, path in ipairs(paths) do
    local exists = file_exists(path)
    if not exists then
        if not opts.force then
            io.stderr:write("rm: cannot remove '" .. path .. "': No such file or directory\n")
        end
    elseif is_dir(path) then
        io.stderr:write("rm: cannot remove '" .. path .. "': Is a directory\n")
    else
        if opts.interactive and not prompt_remove(path) then
            -- Skip.
        else
            local ok, err = os.remove(path)
            if not ok and not opts.force then
                io.stderr:write("rm: cannot remove '" .. path .. "': " .. tostring(err) .. "\n")
            end
        end
    end
end
