local function usage()
    print("usage: passgen [-l N|--length N] [--no-symbols] [--safe] [--count N]")
    print("  -l, --length N  password length (default: 16)")
    print("  --no-symbols    use letters+digits only")
    print("  --safe          use unambiguous chars only")
    print("  --count N       generate N passwords (default: 1)")
    print("  no args         generate 9 safe passwords: 3x len 8, 3x len 12, 3x len 16")
end

local default_len = 16
local length = default_len
local count = 1
local use_symbols = true
local safe_mode = false

local function parse_int(s)
    local n = tonumber(s)
    if not n then
        return nil
    end
    if math.floor(n) ~= n then
        return nil
    end
    return n
end

local i = 1
while i <= (ARGC or 0) do
    local a = tostring(ARGS[i] or "")
    if a == "-h" or a == "--help" then
        usage()
        return
    elseif a == "-l" or a == "--length" then
        if i + 1 > ARGC then
            io.stderr:write("passgen: option requires an argument -- length\n")
            return
        end
        local n = parse_int(ARGS[i + 1])
        if not n or n < 4 then
            io.stderr:write("passgen: invalid length (must be integer >= 4)\n")
            return
        end
        length = n
        i = i + 1
    elseif a == "--count" then
        if i + 1 > ARGC then
            io.stderr:write("passgen: option requires an argument -- count\n")
            return
        end
        local n = parse_int(ARGS[i + 1])
        if not n or n < 1 then
            io.stderr:write("passgen: invalid count (must be integer >= 1)\n")
            return
        end
        count = n
        i = i + 1
    elseif a == "--no-symbols" then
        use_symbols = false
    elseif a == "--safe" then
        safe_mode = true
    else
        io.stderr:write("passgen: unsupported option: " .. a .. "\n")
        return
    end
    i = i + 1
end

local function build_alphabet(is_safe, allow_symbols)
    local lower = is_safe and "abcdefghjkmnpqrstuvwxyz" or "abcdefghijklmnopqrstuvwxyz"
    local upper = is_safe and "ABCDEFGHJKLMNPQRSTUVWXYZ" or "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local digits = is_safe and "23456789" or "0123456789"
    local symbols = "!@#$%^&*()-_=+[]{};:,.?/"

    local alphabet = lower .. upper .. digits
    if allow_symbols then
        alphabet = alphabet .. symbols
    end
    return alphabet
end

local f, err = io.open("/dev/urandom", "rb")
if not f then
    io.stderr:write("passgen: cannot open /dev/urandom: " .. tostring(err) .. "\n")
    return
end

local function random_index(max_n)
    local limit = 256 - (256 % max_n)
    while true do
        local b = f:read(1)
        if not b then
            return nil
        end
        local v = string.byte(b)
        if v < limit then
            return (v % max_n) + 1
        end
    end
end

local function emit_passwords(n_count, n_len, is_safe, allow_symbols)
    local alphabet = build_alphabet(is_safe, allow_symbols)
    if #alphabet < 2 then
        io.stderr:write("passgen: character set is too small\n")
        return false
    end

    for _ = 1, n_count do
        local out = {}
        for j = 1, n_len do
            local idx = random_index(#alphabet)
            if not idx then
                io.stderr:write("passgen: random read failed\n")
                return false
            end
            out[#out + 1] = alphabet:sub(idx, idx)
        end
        print(table.concat(out))
    end

    return true
end

local ok = true
if (ARGC or 0) == 0 then
    ok = emit_passwords(3, 8, true, use_symbols)
    if ok then ok = emit_passwords(3, 12, true, use_symbols) end
    if ok then ok = emit_passwords(3, 16, true, use_symbols) end
else
    ok = emit_passwords(count, length, safe_mode, use_symbols)
end

f:close()
if not ok then
    return
end
