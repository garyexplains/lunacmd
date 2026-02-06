local function resolve_path(path)
    local base = G_CWD or "."
    if path:sub(1, 1) == "/" then
        return path
    end
    return base .. "/" .. path
end

local function build_crc32_table()
    local table_crc = {}
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if (crc & 1) ~= 0 then
                crc = (crc >> 1) ~ 0xEDB88320
            else
                crc = crc >> 1
            end
        end
        table_crc[i] = crc & 0xFFFFFFFF
    end
    return table_crc
end

local CRC32_TABLE = build_crc32_table()

local function crc32_update(crc, data)
    for i = 1, #data do
        local b = string.byte(data, i)
        local idx = (crc ~ b) & 0xFF
        crc = ((crc >> 8) ~ CRC32_TABLE[idx]) & 0xFFFFFFFF
    end
    return crc
end

local function crc32_file(path)
    local resolved = resolve_path(path)
    local f = io.open(resolved, "rb")
    if not f then
        io.stderr:write("cksum: cannot open '" .. resolved .. "'\n")
        return nil
    end

    local crc = 0xFFFFFFFF
    local size = 0

    while true do
        local chunk = f:read(8192)
        if not chunk then
            break
        end
        size = size + #chunk
        crc = crc32_update(crc, chunk)
    end

    f:close()
    crc = (~crc) & 0xFFFFFFFF
    return crc, size, resolved
end

if not ARGC or ARGC == 0 then
    io.stderr:write("cksum: missing file operand\n")
    return
end

for i = 1, ARGC do
    local arg = ARGS[i]
    if arg and arg ~= "" then
        local crc, size, resolved = crc32_file(arg)
        if crc then
            io.write(string.format("%08x %d %s\n", crc, size, resolved))
        end
    else
        io.stderr:write("cksum: missing file operand\n")
    end
end
