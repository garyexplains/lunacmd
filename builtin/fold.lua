local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function fold_hard(line, width)
    local i = 1
    while i <= #line do
        io.write(line:sub(i, i + width - 1), "\n")
        i = i + width
    end
    if #line == 0 then
        io.write("\n")
    end
end

local function fold_spaces(line, width)
    if #line == 0 then
        io.write("\n")
        return
    end

    local rest = line
    while #rest > width do
        local chunk = rest:sub(1, width)
        local split_at = nil
        for i = #chunk, 1, -1 do
            if chunk:sub(i, i):match("%s") then
                split_at = i
                break
            end
        end

        if split_at and split_at > 1 then
            io.write(chunk:sub(1, split_at - 1), "\n")
            rest = rest:sub(split_at + 1)
            rest = rest:gsub("^%s+", "")
        else
            io.write(chunk, "\n")
            rest = rest:sub(width + 1)
        end
    end
    io.write(rest, "\n")
end

local width = 80
local break_spaces = false
local files = {}
local i = 1

while i <= (ARGC or 0) do
    local arg = ARGS[i]
    if arg == "-s" then
        break_spaces = true
        i = i + 1
    elseif arg == "-w" then
        if i + 1 > ARGC then
            io.stderr:write("fold: option requires an argument -- w\n")
            return
        end
        local v = tonumber(ARGS[i + 1])
        if not v or v < 1 or math.floor(v) ~= v then
            io.stderr:write("fold: invalid width: " .. tostring(ARGS[i + 1]) .. "\n")
            return
        end
        width = v
        i = i + 2
    else
        files[#files + 1] = resolve_path(arg or "")
        i = i + 1
    end
end

if #files == 0 then
    io.stderr:write("fold: missing file operand\n")
    return
end

for _, path in ipairs(files) do
    local f = io.open(path, "rb")
    if not f then
        io.stderr:write("fold: cannot open '" .. path .. "'\n")
    else
        for line in f:lines() do
            if break_spaces then
                fold_spaces(line, width)
            else
                fold_hard(line, width)
            end
        end
        f:close()
    end
end
