local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function bytes_to_hex(chunk)
    local out = {}
    for i = 1, #chunk do
        out[#out + 1] = string.format("%02x", string.byte(chunk, i))
    end
    return table.concat(out, " ")
end

local function printable_ascii(b)
    if b >= 32 and b <= 126 then
        return string.char(b)
    end
    return "."
end

local function print_default_dump(content)
    local offset = 0
    local i = 1

    while i <= #content do
        local line = content:sub(i, i + 15)
        local hex_cells = {}
        local ascii_cells = {}
        local j

        for j = 1, 16 do
            if j <= #line then
                local b = string.byte(line, j)
                hex_cells[#hex_cells + 1] = string.format("%02x", b)
                ascii_cells[#ascii_cells + 1] = printable_ascii(b)
            else
                hex_cells[#hex_cells + 1] = "  "
                ascii_cells[#ascii_cells + 1] = " "
            end
        end

        local left = table.concat(hex_cells, " ", 1, 8)
        local right = table.concat(hex_cells, " ", 9, 16)
        local ascii = table.concat(ascii_cells)
        print(string.format("%08x  %s  %s  |%s|", offset, left, right, ascii))

        offset = offset + #line
        i = i + 16
    end
end

local function print_raw_hex_dump(content)
    local i = 1
    while i <= #content do
        local line = content:sub(i, i + 15)
        print(bytes_to_hex(line))
        i = i + 16
    end
end

local use_raw_hex = false
local files = {}
local parse_options = true

for i = 1, (ARGC or 0) do
    local arg = ARGS[i] or ""
    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and (arg == "-h" or arg == "--help") then
        print("usage: hexdump [-x] [FILE]...")
        return
    elseif parse_options and arg == "-x" then
        use_raw_hex = true
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        io.stderr:write("hexdump: unsupported option: " .. arg .. "\n")
        return
    else
        if arg == "-" then
            files[#files + 1] = "-"
        else
            files[#files + 1] = resolve_path(arg)
        end
    end
end

if #files == 0 then
    files[1] = "-"
end

for _, path in ipairs(files) do
    local content = nil

    if path == "-" then
        content = io.read("*a") or ""
    else
        local f = io.open(path, "rb")
        if not f then
            io.stderr:write("hexdump: cannot open '" .. path .. "'\n")
        else
            content = f:read("*a") or ""
            f:close()
        end
    end

    if content ~= nil then
        if use_raw_hex then
            print_raw_hex_dump(content)
        else
            print_default_dump(content)
        end
    end
end
