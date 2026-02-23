local function usage()
    print("usage: pwmgr [--file PATH] [--master PASS] <command> [args...]")
    print("commands:")
    print("  init [--force]")
    print("  list")
    print("  add NAME [--user USER] [--pass PASS] [--note NOTE] [--gen [LEN]] [--safe] [--no-symbols]")
    print("  get NAME")
    print("  rm NAME")
    print("  set NAME [--user USER] [--pass PASS] [--note NOTE]")
    print("  help")
end

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

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local c = f:read("*a") or ""
    f:close()
    return c
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then
        return false
    end
    local ok = f:write(data)
    f:close()
    return ok and true or false
end

local function prompt_secret(prompt)
    local tty_in = io.open("/dev/tty", "r")
    local tty_out = io.open("/dev/tty", "w")
    if not tty_in or not tty_out then
        if tty_in then tty_in:close() end
        if tty_out then tty_out:close() end
        io.stderr:write("pwmgr: cannot access tty for password prompt (use --master)\n")
        return nil
    end

    tty_out:write(prompt)
    tty_out:flush()
    os.execute("stty -echo < /dev/tty")
    local ok, line = pcall(function() return tty_in:read("*l") end)
    os.execute("stty echo < /dev/tty")
    tty_out:write("\n")
    tty_out:flush()

    tty_in:close()
    tty_out:close()

    if not ok then
        io.stderr:write("pwmgr: failed to read password\n")
        return nil
    end
    return line or ""
end

local function tmp_name(prefix)
    prefix = prefix or "pwmgr"
    local rand = tostring(math.random(100000, 999999))
    return "/tmp/" .. prefix .. "-" .. tostring(os.time()) .. "-" .. rand
end

local function encrypt_to_file(path, plaintext, master)
    local in_path = tmp_name("pwmgr-in")
    local out_path = tmp_name("pwmgr-out")
    local ok = write_file(in_path, plaintext)
    if not ok then
        return false, "cannot write temp input"
    end

    local cmd = "openssl enc -aes-256-cbc -pbkdf2 -salt -a -in "
        .. shell_quote(in_path)
        .. " -out "
        .. shell_quote(out_path)
        .. " -pass pass:"
        .. shell_quote(master)

    local os_ok = os.execute(cmd)
    if not os_ok then
        os.remove(in_path)
        os.remove(out_path)
        return false, "encryption failed (is openssl installed?)"
    end

    local enc = read_file(out_path)
    os.remove(in_path)
    os.remove(out_path)
    if enc == nil then
        return false, "cannot read encrypted temp output"
    end
    if not write_file(path, enc) then
        return false, "cannot write vault file"
    end
    os.execute("chmod 600 " .. shell_quote(path))
    return true
end

local function decrypt_from_file(path, master)
    local in_path = tmp_name("pwmgr-in")
    local out_path = tmp_name("pwmgr-out")

    local enc = read_file(path)
    if enc == nil then
        return nil, "vault does not exist"
    end
    if not write_file(in_path, enc) then
        return nil, "cannot write decrypt temp input"
    end

    local cmd = "openssl enc -d -aes-256-cbc -pbkdf2 -a -in "
        .. shell_quote(in_path)
        .. " -out "
        .. shell_quote(out_path)
        .. " -pass pass:"
        .. shell_quote(master)

    local os_ok = os.execute(cmd)
    os.remove(in_path)
    if not os_ok then
        os.remove(out_path)
        return nil, "decrypt failed (wrong password or corrupted vault)"
    end

    local plain = read_file(out_path)
    os.remove(out_path)
    if plain == nil then
        return nil, "cannot read decrypted content"
    end
    return plain
end

local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\t", "\\t")
    s = s:gsub("\n", "\\n")
    return s
end

local function unesc(s)
    local out = {}
    local i = 1
    s = tostring(s or "")
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" and i < #s then
            local n = s:sub(i + 1, i + 1)
            if n == "t" then
                out[#out + 1] = "\t"
                i = i + 2
            elseif n == "n" then
                out[#out + 1] = "\n"
                i = i + 2
            elseif n == "\\" then
                out[#out + 1] = "\\"
                i = i + 2
            else
                out[#out + 1] = n
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function serialize_db(db)
    local lines = {"LUNAPWM1"}
    local names = {}
    for name, _ in pairs(db) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local e = db[name] or {}
        lines[#lines + 1] = table.concat({
            esc(name),
            esc(e.user or ""),
            esc(e.pass or ""),
            esc(e.note or ""),
            esc(e.updated or ""),
        }, "\t")
    end

    return table.concat(lines, "\n") .. "\n"
end

local function deserialize_db(s)
    local db = {}
    local first = true
    for line in tostring(s or ""):gmatch("([^\n]*)\n?") do
        if line == "" and first then
            return nil, "empty vault"
        end
        if first then
            first = false
            if line ~= "LUNAPWM1" then
                return nil, "invalid vault header"
            end
        elseif line ~= "" then
            local fields = {}
            local start = 1
            while true do
                local t = line:find("\t", start, true)
                if not t then
                    fields[#fields + 1] = line:sub(start)
                    break
                end
                fields[#fields + 1] = line:sub(start, t - 1)
                start = t + 1
            end
            local name = unesc(fields[1] or "")
            if name ~= "" then
                db[name] = {
                    user = unesc(fields[2] or ""),
                    pass = unesc(fields[3] or ""),
                    note = unesc(fields[4] or ""),
                    updated = unesc(fields[5] or ""),
                }
            end
        end
    end
    return db
end

local function generate_password(length, safe_mode, use_symbols)
    local lower = safe_mode and "abcdefghjkmnpqrstuvwxyz" or "abcdefghijklmnopqrstuvwxyz"
    local upper = safe_mode and "ABCDEFGHJKLMNPQRSTUVWXYZ" or "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local digits = safe_mode and "23456789" or "0123456789"
    local symbols = "!@#$%^&*()-_=+[]{};:,.?/"

    local alphabet = lower .. upper .. digits
    if use_symbols then
        alphabet = alphabet .. symbols
    end

    local f, err = io.open("/dev/urandom", "rb")
    if not f then
        return nil, "cannot open /dev/urandom: " .. tostring(err)
    end

    local out = {}
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

    for i = 1, length do
        local idx = random_index(#alphabet)
        if not idx then
            f:close()
            return nil, "random read failed"
        end
        out[#out + 1] = alphabet:sub(idx, idx)
    end

    f:close()
    return table.concat(out)
end

local vault_path = resolve_path("~/.lunacmd/pwmgr.db.enc")
local master_override = nil

local pos = 1
while pos <= (ARGC or 0) do
    local a = tostring(ARGS[pos] or "")
    if a == "--file" then
        if pos + 1 > ARGC then
            io.stderr:write("pwmgr: option requires an argument -- file\n")
            return
        end
        vault_path = resolve_path(ARGS[pos + 1])
        pos = pos + 2
    elseif a == "--master" then
        if pos + 1 > ARGC then
            io.stderr:write("pwmgr: option requires an argument -- master\n")
            return
        end
        master_override = tostring(ARGS[pos + 1] or "")
        pos = pos + 2
    else
        break
    end
end

local cmd = tostring(ARGS[pos] or "")
if cmd == "" or cmd == "help" or cmd == "-h" or cmd == "--help" then
    usage()
    return
end

local function get_master(confirm)
    if master_override ~= nil then
        if confirm then
            return master_override, master_override
        end
        return master_override
    end
    if confirm then
        local a = prompt_secret("Master password: ")
        if a == nil then return nil, nil end
        local b = prompt_secret("Confirm master password: ")
        if b == nil then return nil, nil end
        return a, b
    end
    return prompt_secret("Master password: ")
end

local function load_db()
    if not file_exists(vault_path) then
        return nil, "vault not found; run: pwmgr init"
    end
    local master = get_master(false)
    if master == nil then
        return nil, "missing master password"
    end
    local plain, err = decrypt_from_file(vault_path, master)
    if not plain then
        return nil, err
    end
    local db, derr = deserialize_db(plain)
    if not db then
        return nil, derr
    end
    return { db = db, master = master }
end

local function save_db(db, master)
    local plain = serialize_db(db)
    local ok, err = encrypt_to_file(vault_path, plain, master)
    if not ok then
        return nil, err
    end
    return true
end

if cmd == "init" then
    local force = false
    local j = pos + 1
    while j <= (ARGC or 0) do
        local a = tostring(ARGS[j] or "")
        if a == "--force" then
            force = true
        else
            io.stderr:write("pwmgr init: unsupported option: " .. a .. "\n")
            return
        end
        j = j + 1
    end

    if file_exists(vault_path) and not force then
        io.stderr:write("pwmgr: vault already exists (use init --force to overwrite)\n")
        return
    end

    local p1, p2 = get_master(true)
    if p1 == nil then
        return
    end
    if p1 == "" then
        io.stderr:write("pwmgr: master password cannot be empty\n")
        return
    end
    if p1 ~= p2 then
        io.stderr:write("pwmgr: passwords do not match\n")
        return
    end

    local ok, err = save_db({}, p1)
    if not ok then
        io.stderr:write("pwmgr: " .. tostring(err) .. "\n")
        return
    end
    print("pwmgr: initialized vault at " .. vault_path)
    return
end

local loaded, lerr = load_db()
if not loaded then
    io.stderr:write("pwmgr: " .. tostring(lerr) .. "\n")
    return
end

local db = loaded.db
local master = loaded.master

if cmd == "list" then
    local names = {}
    for name, _ in pairs(db) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local e = db[name] or {}
        local u = tostring(e.user or "")
        if u ~= "" then
            print(name .. "\t(" .. u .. ")")
        else
            print(name)
        end
    end
    return
end

if cmd == "get" then
    local name = tostring(ARGS[pos + 1] or "")
    if name == "" then
        io.stderr:write("pwmgr get: missing NAME\n")
        return
    end
    local e = db[name]
    if not e then
        io.stderr:write("pwmgr: entry not found: " .. name .. "\n")
        return
    end
    print("name: " .. name)
    if tostring(e.user or "") ~= "" then print("user: " .. tostring(e.user)) end
    print("pass: " .. tostring(e.pass or ""))
    if tostring(e.note or "") ~= "" then print("note: " .. tostring(e.note)) end
    if tostring(e.updated or "") ~= "" then print("updated: " .. tostring(e.updated)) end
    return
end

if cmd == "rm" then
    local name = tostring(ARGS[pos + 1] or "")
    if name == "" then
        io.stderr:write("pwmgr rm: missing NAME\n")
        return
    end
    if not db[name] then
        io.stderr:write("pwmgr: entry not found: " .. name .. "\n")
        return
    end
    db[name] = nil
    local ok, err = save_db(db, master)
    if not ok then
        io.stderr:write("pwmgr: " .. tostring(err) .. "\n")
        return
    end
    print("pwmgr: removed " .. name)
    return
end

if cmd == "add" or cmd == "set" then
    local name = tostring(ARGS[pos + 1] or "")
    if name == "" then
        io.stderr:write("pwmgr " .. cmd .. ": missing NAME\n")
        return
    end

    local entry = db[name] or { user = "", pass = "", note = "", updated = "" }
    local user_set = false
    local pass_set = false
    local note_set = false
    local gen = false
    local gen_len = 16
    local gen_safe = false
    local gen_no_symbols = false

    local j = pos + 2
    while j <= (ARGC or 0) do
        local a = tostring(ARGS[j] or "")
        if a == "--user" then
            if j + 1 > ARGC then
                io.stderr:write("pwmgr " .. cmd .. ": option requires an argument -- user\n")
                return
            end
            entry.user = tostring(ARGS[j + 1] or "")
            user_set = true
            j = j + 2
        elseif a == "--pass" then
            if j + 1 > ARGC then
                io.stderr:write("pwmgr " .. cmd .. ": option requires an argument -- pass\n")
                return
            end
            entry.pass = tostring(ARGS[j + 1] or "")
            pass_set = true
            j = j + 2
        elseif a == "--note" then
            if j + 1 > ARGC then
                io.stderr:write("pwmgr " .. cmd .. ": option requires an argument -- note\n")
                return
            end
            entry.note = tostring(ARGS[j + 1] or "")
            note_set = true
            j = j + 2
        elseif a == "--gen" then
            gen = true
            if j + 1 <= ARGC then
                local maybe = tostring(ARGS[j + 1] or "")
                local n = tonumber(maybe)
                if n and math.floor(n) == n and n >= 4 then
                    gen_len = n
                    j = j + 2
                else
                    j = j + 1
                end
            else
                j = j + 1
            end
        elseif a == "--safe" then
            gen_safe = true
            j = j + 1
        elseif a == "--no-symbols" then
            gen_no_symbols = true
            j = j + 1
        else
            io.stderr:write("pwmgr " .. cmd .. ": unsupported option: " .. a .. "\n")
            return
        end
    end

    if gen then
        local p, perr = generate_password(gen_len, gen_safe, not gen_no_symbols)
        if not p then
            io.stderr:write("pwmgr: " .. tostring(perr) .. "\n")
            return
        end
        entry.pass = p
        pass_set = true
    end

    if cmd == "add" and db[name] then
        io.stderr:write("pwmgr: entry already exists: " .. name .. " (use set to modify)\n")
        return
    end

    if cmd == "add" and not pass_set then
        local p = prompt_secret("Entry password: ")
        if p == nil then
            return
        end
        entry.pass = p
        pass_set = true
    end

    if cmd == "set" and not (user_set or pass_set or note_set) then
        io.stderr:write("pwmgr set: no fields changed\n")
        return
    end

    if tostring(entry.pass or "") == "" then
        io.stderr:write("pwmgr: password cannot be empty\n")
        return
    end

    entry.updated = os.date("!%Y-%m-%dT%H:%M:%SZ")
    db[name] = entry

    local ok, err = save_db(db, master)
    if not ok then
        io.stderr:write("pwmgr: " .. tostring(err) .. "\n")
        return
    end

    print("pwmgr: saved " .. name)
    if gen then
        print("generated password: " .. tostring(entry.pass))
    end
    return
end

io.stderr:write("pwmgr: unknown command: " .. cmd .. "\n")
usage()
