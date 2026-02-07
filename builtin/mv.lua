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

local function basename(path)
    local stripped = path:gsub("/+$", "")
    local name = stripped:match("([^/]+)$")
    if name then
        return name
    end
    return stripped
end

local function join_path(a, b)
    if a == "/" then
        return "/" .. b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

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
        return absolute and "/" or "."
    end
    return normalized
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    local isdir = _ISDIR and _ISDIR(path)
    return isdir == true
end

local function is_dir(path)
    if type(_ISDIR) ~= "function" then
        return false
    end
    local ok = _ISDIR(path)
    return ok == true
end

local function mkdir_if_needed(path)
    if type(_MKDIR) ~= "function" then
        return false, "internal mkdir function is unavailable"
    end
    local ok, err = _MKDIR(path)
    if ok then
        return true
    end
    return false, err or "unknown mkdir error"
end

local function prompt_overwrite(dst)
    io.write("mv: overwrite '" .. dst .. "'? ")
    io.flush()
    local answer = io.read("*l")
    if not answer then
        return false
    end
    return answer:match("^[Yy]") ~= nil
end

local function is_subpath(path, root)
    if path == root then
        return true
    end
    if root == "/" then
        return true
    end
    return path:sub(1, #root + 1) == (root .. "/")
end

local opts = {
    force = false,
    interactive = false,
    verbose = false,
}

local paths = {}
local parse_options = true

if not ARGC or ARGC == 0 then
    io.stderr:write("mv: missing file operand\n")
    return
end

for i = 1, ARGC do
    local arg = ARGS[i] or ""
    if parse_options and (arg == "-h" or arg == "--help") then
        print("usage: mv [-f|--force] [-i|--interactive] [-v|--verbose] SRC... DST")
        return
    end
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and arg:sub(1, 2) == "--" and #arg > 2 then
        if arg == "--force" then
            opts.force = true
            opts.interactive = false
        elseif arg == "--interactive" then
            opts.interactive = true
            opts.force = false
        elseif arg == "--verbose" then
            opts.verbose = true
        else
            io.stderr:write("mv: unsupported option: " .. arg .. "\n")
            return
        end
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        for j = 2, #arg do
            local c = arg:sub(j, j)
            if c == "f" then
                opts.force = true
                opts.interactive = false
            elseif c == "i" then
                opts.interactive = true
                opts.force = false
            elseif c == "v" then
                opts.verbose = true
            else
                io.stderr:write("mv: unsupported option: -" .. c .. "\n")
                return
            end
        end
    else
        paths[#paths + 1] = normalize_path(resolve_path(arg))
    end
end

if #paths < 2 then
    io.stderr:write("mv: missing destination file operand\n")
    return
end

local function remove_any(path)
    if is_dir(path) then
        local entries, err = _LISTDIR(path)
        if not entries then
            io.stderr:write("mv: cannot read directory '" .. path .. "': " .. tostring(err) .. "\n")
            return false
        end
        for _, name in ipairs(entries) do
            if name ~= "." and name ~= ".." then
                if not remove_any(join_path(path, name)) then
                    return false
                end
            end
        end
    end
    local ok, err = os.remove(path)
    if not ok then
        io.stderr:write("mv: cannot remove '" .. path .. "': " .. tostring(err) .. "\n")
        return false
    end
    return true
end

local copy_any
local function copy_file(src, dst)
    local srcf = io.open(src, "rb")
    if not srcf then
        io.stderr:write("mv: cannot open '" .. src .. "'\n")
        return false
    end

    local dstf = io.open(dst, "wb")
    if not dstf then
        srcf:close()
        io.stderr:write("mv: cannot write '" .. dst .. "'\n")
        return false
    end

    while true do
        local chunk = srcf:read(8192)
        if not chunk then
            break
        end
        local ok = dstf:write(chunk)
        if not ok then
            srcf:close()
            dstf:close()
            io.stderr:write("mv: write failed for '" .. dst .. "'\n")
            return false
        end
    end

    srcf:close()
    dstf:close()
    return true
end

local function copy_dir(src, dst)
    local ok, err = mkdir_if_needed(dst)
    if not ok then
        io.stderr:write("mv: cannot create directory '" .. dst .. "': " .. tostring(err) .. "\n")
        return false
    end

    local entries, list_err = _LISTDIR(src)
    if not entries then
        io.stderr:write("mv: cannot read directory '" .. src .. "': " .. tostring(list_err) .. "\n")
        return false
    end

    for _, name in ipairs(entries) do
        if name ~= "." and name ~= ".." then
            if not copy_any(join_path(src, name), join_path(dst, name)) then
                return false
            end
        end
    end
    return true
end

copy_any = function(src, dst)
    if is_dir(src) then
        return copy_dir(src, dst)
    end
    return copy_file(src, dst)
end

local function move_one(src, dst)
    if src == dst then
        return true
    end

    if not file_exists(src) then
        io.stderr:write("mv: cannot stat '" .. src .. "'\n")
        return false
    end

    if is_dir(src) and is_subpath(dst, src) then
        io.stderr:write("mv: cannot move '" .. src .. "' to a subdirectory of itself, '" .. dst .. "'\n")
        return false
    end

    if opts.interactive and file_exists(dst) then
        if not prompt_overwrite(dst) then
            return true
        end
    end

    if opts.force and file_exists(dst) and is_dir(src) and not is_dir(dst) then
        local ok = os.remove(dst)
        if not ok then
            io.stderr:write("mv: cannot remove '" .. dst .. "'\n")
            return false
        end
    end

    local renamed, rename_err = os.rename(src, dst)
    if renamed then
        if opts.verbose then
            print("'" .. src .. "' -> '" .. dst .. "'")
        end
        return true
    end

    if not copy_any(src, dst) then
        return false
    end
    if not remove_any(src) then
        return false
    end

    if opts.verbose then
        print("'" .. src .. "' -> '" .. dst .. "'")
    end
    return true
end

local dest = paths[#paths]
local sources = {}
for i = 1, #paths - 1 do
    sources[#sources + 1] = paths[i]
end

local dest_is_dir = is_dir(dest)
if #sources > 1 and not dest_is_dir then
    io.stderr:write("mv: target '" .. dest .. "' is not a directory\n")
    return
end

local any_error = false
for i = 1, #sources do
    local src = sources[i]
    local final_dst = dest
    if dest_is_dir then
        final_dst = join_path(dest, basename(src))
    end
    if not move_one(src, final_dst) then
        any_error = true
    end
end

if any_error then
    -- Keep behavior consistent with other builtins.
end
