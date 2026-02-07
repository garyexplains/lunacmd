local MODE_TYPE = 0xF000
local MODE_DIR = 0x4000
local MODE_SYMLINK = 0xA000
local MODE_FIFO = 0x1000
local MODE_SOCKET = 0xC000
local MODE_BLOCK = 0x6000
local MODE_CHAR = 0x2000

local function usage()
    print("usage: ls [-1AaCcdFeFilLnpRrSstuvXxh] [-T N] [-w N] [--color[=WHEN]] [FILE]...")
    print("  -1      list one entry per line")
    print("  -A      list all except . and ..")
    print("  -a      list all including . and ..")
    print("  -C      list by columns")
    print("  -c      use ctime for sorting with -t")
    print("  --color[=always|never|auto]  colorize output")
    print("  -d      list directories themselves, not their contents")
    print("  -e      show full timestamp")
    print("  -F      append type indicator (*/=@|)")
    print("  -i      print inode number")
    print("  -l      long format")
    print("  -n      numeric uid/gid")
    print("  -p      append type indicator (/=@|)")
    print("  -L      follow symlinks when getting entry info")
    print("  -R      recurse into subdirectories")
    print("  -r      reverse sort order")
    print("  -S      sort by size")
    print("  -s      print size in blocks")
    print("  -T N    tab stop for column output")
    print("  -t      sort by time")
    print("  -u      use atime for sorting with -t")
    print("  -v      natural version sort")
    print("  -w N    terminal width for columns")
    print("  -x      list by lines")
    print("  -X      sort by extension")
    print("  -h      human-readable sizes")
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
    if path == "" then
        return base
    end
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

local function join_path(a, b)
    if a == "/" then
        return "/" .. b
    end
    return a .. "/" .. b
end

local function basename(path)
    return (path:gsub("/+$", ""):match("([^/]+)$") or path)
end

local function has_glob_chars(s)
    return tostring(s or ""):find("[%*%?%[]") ~= nil
end

local function split_dir_base(path)
    local slash = path:match("^.*()/")
    if slash then
        local dir = path:sub(1, slash - 1)
        if dir == "" then
            dir = "/"
        end
        return dir, path:sub(slash + 1)
    end
    return ".", path
end

local function glob_to_lua_pattern(glob)
    local out = { "^" }
    local i = 1
    while i <= #glob do
        local c = glob:sub(i, i)
        if c == "*" then
            out[#out + 1] = ".*"
        elseif c == "?" then
            out[#out + 1] = "."
        elseif c == "[" then
            local j = glob:find("%]", i + 1, true)
            if j then
                local cls = glob:sub(i + 1, j - 1)
                if cls:sub(1, 1) == "!" then
                    cls = "^" .. cls:sub(2)
                end
                cls = cls:gsub("%%", "%%%%")
                out[#out + 1] = "[" .. cls .. "]"
                i = j
            else
                out[#out + 1] = "%%%["
            end
        elseif c:match("[%(%)%%%.%+%-%^%$]") then
            out[#out + 1] = "%" .. c
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

local function expand_glob_arg(raw)
    local dir_part, base_glob = split_dir_base(raw)
    local scan_dir_path = resolve_path(dir_part)
    local names, err = _LISTDIR(scan_dir_path)
    local matches = {}
    local pattern

    if not names then
        return { raw }, err
    end

    pattern = glob_to_lua_pattern(base_glob)
    for _, name in ipairs(names) do
        if name ~= "." and name ~= ".." and name:match(pattern) then
            if dir_part == "." then
                matches[#matches + 1] = name
            elseif dir_part == "/" then
                matches[#matches + 1] = "/" .. name
            else
                matches[#matches + 1] = dir_part .. "/" .. name
            end
        end
    end
    table.sort(matches)
    if #matches == 0 then
        return { raw }
    end
    return matches
end

local function stat_path(path, follow)
    if type(_STAT) ~= "function" then
        return nil, "internal stat helper unavailable"
    end
    return _STAT(path, follow and true or false)
end

local function readlink_path(path)
    if type(_READLINK) ~= "function" then
        return nil
    end
    return _READLINK(path)
end

local function uid_name(uid)
    if type(_UID_NAME) ~= "function" then
        return nil
    end
    return _UID_NAME(uid)
end

local function gid_name(gid)
    if type(_GID_NAME) ~= "function" then
        return nil
    end
    return _GID_NAME(gid)
end

local function isatty_stdout()
    if type(_ISATTY) ~= "function" then
        return false
    end
    return _ISATTY(1) == true
end

local function file_type_char(mode)
    local t = mode & MODE_TYPE
    if t == MODE_DIR then
        return "d"
    elseif t == MODE_SYMLINK then
        return "l"
    elseif t == MODE_FIFO then
        return "p"
    elseif t == MODE_SOCKET then
        return "s"
    elseif t == MODE_BLOCK then
        return "b"
    elseif t == MODE_CHAR then
        return "c"
    end
    return "-"
end

local function mode_string(mode)
    local function rwx(read_bit, write_bit, exec_bit)
        local r = (mode & read_bit) ~= 0 and "r" or "-"
        local w = (mode & write_bit) ~= 0 and "w" or "-"
        local x = (mode & exec_bit) ~= 0 and "x" or "-"
        return r .. w .. x
    end
    return file_type_char(mode)
        .. rwx(0x100, 0x80, 0x40)
        .. rwx(0x20, 0x10, 0x8)
        .. rwx(0x4, 0x2, 0x1)
end

local function ext_key(name)
    local base = name
    if base == "." or base == ".." then
        return ""
    end
    local dot = base:match("^.*()%.")
    if dot and dot > 1 and dot < #base then
        return base:sub(dot + 1):lower()
    end
    return ""
end

local function split_version(s)
    local parts = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c:match("%d") then
            local j = i
            while j <= #s and s:sub(j, j):match("%d") do
                j = j + 1
            end
            parts[#parts + 1] = { num = true, val = tonumber(s:sub(i, j - 1)) or 0 }
            i = j
        else
            local j = i
            while j <= #s and not s:sub(j, j):match("%d") do
                j = j + 1
            end
            parts[#parts + 1] = { num = false, val = s:sub(i, j - 1):lower() }
            i = j
        end
    end
    return parts
end

local function version_cmp(a, b)
    local pa = split_version(a)
    local pb = split_version(b)
    local n = math.max(#pa, #pb)
    for i = 1, n do
        local xa = pa[i]
        local xb = pb[i]
        if not xa then
            return -1
        end
        if not xb then
            return 1
        end
        if xa.num and xb.num then
            if xa.val ~= xb.val then
                return xa.val < xb.val and -1 or 1
            end
        elseif xa.num ~= xb.num then
            return xa.num and -1 or 1
        else
            if xa.val ~= xb.val then
                return xa.val < xb.val and -1 or 1
            end
        end
    end
    return 0
end

local function human_size(n)
    local units = { "B", "K", "M", "G", "T", "P" }
    local v = tonumber(n) or 0
    local i = 1
    while v >= 1024 and i < #units do
        v = v / 1024
        i = i + 1
    end
    if i == 1 then
        return string.format("%d%s", math.floor(v), units[i])
    end
    if v >= 10 then
        return string.format("%.0f%s", v, units[i])
    end
    return string.format("%.1f%s", v, units[i])
end

local function blocks_1k(st)
    if st.blocks and st.blocks > 0 then
        return math.floor((st.blocks + 1) / 2)
    end
    return math.floor(((st.size or 0) + 1023) / 1024)
end

local function format_time(ts, full)
    local t = tonumber(ts) or 0
    if full then
        return os.date("%Y-%m-%d %H:%M:%S", t)
    end
    local now = os.time()
    if t > now + 3600 or t < now - (180 * 24 * 3600) then
        return os.date("%b %e  %Y", t)
    end
    return os.date("%b %e %H:%M", t)
end

local function colorize(text, entry, enabled)
    if not enabled then
        return text
    end
    local code = nil
    local kind = entry.st and entry.st.kind or "file"
    if kind == "dir" then
        code = "34"
    elseif kind == "symlink" then
        code = "36"
    elseif kind == "socket" then
        code = "35"
    elseif kind == "fifo" then
        code = "33"
    elseif entry.st and entry.st.executable then
        code = "32"
    end
    if not code then
        return text
    end
    return "\27[" .. code .. "m" .. text .. "\27[0m"
end

local function indicator_for(entry, slash_only)
    local kind = entry.st and entry.st.kind or "file"
    if kind == "dir" then
        return "/"
    end
    if kind == "symlink" then
        return "@"
    end
    if kind == "socket" then
        return "="
    end
    if kind == "fifo" then
        return "|"
    end
    if (not slash_only) and entry.st and entry.st.executable then
        return "*"
    end
    return ""
end

local opts = {
    one = false,
    almost_all = false,
    all = false,
    columns = false,
    sort_ctime = false,
    color = "auto",
    dir_itself = false,
    full_time = false,
    classify = false,
    inode = false,
    long = false,
    numeric = false,
    classify_slash = false,
    follow_links = false,
    recurse = false,
    reverse = false,
    sort_size = false,
    show_blocks = false,
    tabstop = 8,
    sort_time = false,
    sort_atime = false,
    sort_version = false,
    width = tonumber(os.getenv("COLUMNS") or "") or 80,
    list_by_lines = false,
    sort_ext = false,
    human = false,
}

local targets = {}
local parse_options = true
local i = 1

while i <= (ARGC or 0) do
    local arg = tostring(ARGS[i] or "")

    if parse_options and arg == "--" then
        parse_options = false
    elseif parse_options and arg == "--help" then
        usage()
        return
    elseif parse_options and arg:match("^%-%-color") then
        local v = arg:match("^%-%-color=(.+)$")
        if v == nil then
            v = "always"
        end
        if v ~= "always" and v ~= "never" and v ~= "auto" then
            io.stderr:write("ls: invalid --color value: " .. tostring(v) .. "\n")
            return
        end
        opts.color = v
    elseif parse_options and arg:sub(1, 1) == "-" and #arg > 1 then
        local j = 2
        while j <= #arg do
            local c = arg:sub(j, j)
            if c == "1" then
                opts.one = true
                opts.columns = false
                opts.list_by_lines = false
            elseif c == "A" then
                opts.almost_all = true
            elseif c == "a" then
                opts.all = true
            elseif c == "C" then
                opts.columns = true
                opts.one = false
            elseif c == "c" then
                opts.sort_ctime = true
            elseif c == "d" then
                opts.dir_itself = true
            elseif c == "e" then
                opts.full_time = true
            elseif c == "F" then
                opts.classify = true
            elseif c == "i" then
                opts.inode = true
            elseif c == "l" then
                opts.long = true
            elseif c == "n" then
                opts.numeric = true
            elseif c == "p" then
                opts.classify_slash = true
            elseif c == "L" then
                opts.follow_links = true
            elseif c == "R" then
                opts.recurse = true
            elseif c == "r" then
                opts.reverse = true
            elseif c == "S" then
                opts.sort_size = true
                opts.sort_time = false
                opts.sort_ext = false
                opts.sort_version = false
            elseif c == "s" then
                opts.show_blocks = true
            elseif c == "t" then
                opts.sort_time = true
                opts.sort_size = false
                opts.sort_ext = false
                opts.sort_version = false
            elseif c == "u" then
                opts.sort_atime = true
            elseif c == "v" then
                opts.sort_version = true
                opts.sort_time = false
                opts.sort_size = false
                opts.sort_ext = false
            elseif c == "w" then
                local val = nil
                if j < #arg then
                    val = tonumber(arg:sub(j + 1))
                    j = #arg
                else
                    i = i + 1
                    val = tonumber(ARGS[i] or "")
                end
                if not val or val < 1 then
                    io.stderr:write("ls: invalid width\n")
                    return
                end
                opts.width = math.floor(val)
                break
            elseif c == "x" then
                opts.list_by_lines = true
                opts.columns = true
                opts.one = false
            elseif c == "X" then
                opts.sort_ext = true
                opts.sort_time = false
                opts.sort_size = false
                opts.sort_version = false
            elseif c == "T" then
                local val = nil
                if j < #arg then
                    val = tonumber(arg:sub(j + 1))
                    j = #arg
                else
                    i = i + 1
                    val = tonumber(ARGS[i] or "")
                end
                if not val or val < 1 then
                    io.stderr:write("ls: invalid tabstop\n")
                    return
                end
                opts.tabstop = math.floor(val)
                break
            elseif c == "h" then
                opts.human = true
            else
                io.stderr:write("ls: unsupported option: -" .. c .. "\n")
                return
            end
            j = j + 1
        end
    else
        if has_glob_chars(arg) then
            local expanded = expand_glob_arg(arg)
            for _, v in ipairs(expanded) do
                targets[#targets + 1] = v
            end
        else
            targets[#targets + 1] = arg
        end
    end

    i = i + 1
end

if #targets == 0 then
    targets[1] = "."
end

if opts.long then
    opts.columns = false
    opts.one = true
end

local color_enabled = false
if opts.color == "always" then
    color_enabled = true
elseif opts.color == "auto" then
    local term = os.getenv("TERM") or ""
    color_enabled = isatty_stdout() and term ~= "" and term ~= "dumb"
end

local function include_name(name)
    if opts.all then
        return true
    end
    if opts.almost_all then
        return name ~= "." and name ~= ".."
    end
    return name:sub(1, 1) ~= "."
end

local function build_entry(name, full_path, display_name)
    local lst, lerr = stat_path(full_path, false)
    if not lst then
        return nil, lerr
    end
    local st = lst
    if opts.follow_links and lst.kind == "symlink" then
        local followed = stat_path(full_path, true)
        if followed then
            st = followed
        end
    end

    return {
        name = name,
        display = display_name or name,
        path = full_path,
        st = st,
        lst = lst,
        link_target = (lst.kind == "symlink") and readlink_path(full_path) or nil,
    }
end

local function get_sort_time(entry)
    if opts.sort_atime then
        return tonumber(entry.st.atime) or 0
    end
    if opts.sort_ctime then
        return tonumber(entry.st.ctime) or 0
    end
    return tonumber(entry.st.mtime) or 0
end

local function cmp_entries(a, b)
    local cmp = 0

    if opts.sort_size then
        local sa = tonumber(a.st.size) or 0
        local sb = tonumber(b.st.size) or 0
        if sa ~= sb then
            cmp = (sa > sb) and -1 or 1
        end
    elseif opts.sort_time then
        local ta = get_sort_time(a)
        local tb = get_sort_time(b)
        if ta ~= tb then
            cmp = (ta > tb) and -1 or 1
        end
    elseif opts.sort_ext then
        local ea = ext_key(a.name)
        local eb = ext_key(b.name)
        if ea ~= eb then
            cmp = (ea < eb) and -1 or 1
        end
    elseif opts.sort_version then
        cmp = version_cmp(a.name, b.name)
    end

    if cmp == 0 then
        if a.name ~= b.name then
            cmp = (a.name < b.name) and -1 or 1
        elseif a.path ~= b.path then
            cmp = (a.path < b.path) and -1 or 1
        end
    end

    if opts.reverse then
        cmp = -cmp
    end
    return cmp < 0
end

local function classify_suffix(entry)
    if opts.classify then
        return indicator_for(entry, false)
    end
    if opts.classify_slash then
        return indicator_for(entry, true)
    end
    return ""
end

local function render_name(entry)
    local base_text = entry.display .. classify_suffix(entry)
    return colorize(base_text, entry, color_enabled)
end

local function render_size(st)
    local n = tonumber(st.size) or 0
    if opts.human then
        return human_size(n)
    end
    return tostring(n)
end

local function render_owner(st)
    if opts.numeric then
        return tostring(st.uid or 0), tostring(st.gid or 0)
    end
    local u = uid_name(st.uid or 0) or tostring(st.uid or 0)
    local g = gid_name(st.gid or 0) or tostring(st.gid or 0)
    return u, g
end

local function format_long_rows(entries)
    local rows = {}
    local w_inode, w_blocks, w_nlink, w_user, w_group, w_size = 0, 0, 0, 0, 0, 0

    for _, e in ipairs(entries) do
        local inode = tostring(e.st.ino or 0)
        local blks = tostring(blocks_1k(e.st))
        local nlink = tostring(e.st.nlink or 1)
        local user, group = render_owner(e.st)
        local size = render_size(e.st)

        if #inode > w_inode then w_inode = #inode end
        if #blks > w_blocks then w_blocks = #blks end
        if #nlink > w_nlink then w_nlink = #nlink end
        if #user > w_user then w_user = #user end
        if #group > w_group then w_group = #group end
        if #size > w_size then w_size = #size end

        rows[#rows + 1] = {
            inode = inode,
            blocks = blks,
            mode = mode_string(e.lst.mode or e.st.mode or 0),
            nlink = nlink,
            user = user,
            group = group,
            size = size,
            time = format_time(get_sort_time(e), opts.full_time),
            name = render_name(e),
            link = e.link_target,
            is_link = (e.lst.kind == "symlink"),
        }
    end

    for _, r in ipairs(rows) do
        local parts = {}
        if opts.inode then
            parts[#parts + 1] = string.format("%" .. w_inode .. "s", r.inode)
        end
        if opts.show_blocks then
            parts[#parts + 1] = string.format("%" .. w_blocks .. "s", r.blocks)
        end
        parts[#parts + 1] = r.mode
        parts[#parts + 1] = string.format("%" .. w_nlink .. "s", r.nlink)
        parts[#parts + 1] = string.format("%-" .. w_user .. "s", r.user)
        parts[#parts + 1] = string.format("%-" .. w_group .. "s", r.group)
        parts[#parts + 1] = string.format("%" .. w_size .. "s", r.size)
        parts[#parts + 1] = r.time
        parts[#parts + 1] = r.name
        if r.is_link and r.link then
            parts[#parts + 1] = "->"
            parts[#parts + 1] = r.link
        end
        print(table.concat(parts, " "))
    end
end

local function print_column_layout(entries)
    local rendered = {}
    local maxw = 0
    for _, e in ipairs(entries) do
        local pfx = ""
        if opts.inode then
            pfx = pfx .. tostring(e.st.ino or 0) .. " "
        end
        if opts.show_blocks then
            pfx = pfx .. tostring(blocks_1k(e.st)) .. " "
        end
        local text = pfx .. render_name(e)
        local plain = pfx .. e.display .. classify_suffix(e)
        rendered[#rendered + 1] = { text = text, plainw = #plain }
        if #plain > maxw then
            maxw = #plain
        end
    end

    if #rendered == 0 then
        return
    end

    local pad = math.max(1, opts.tabstop)
    local colw = maxw + pad
    local ncols = math.max(1, math.floor((opts.width + pad) / colw))
    ncols = math.min(ncols, #rendered)
    local nrows = math.ceil(#rendered / ncols)

    if ncols <= 1 then
        for _, c in ipairs(rendered) do
            print(c.text)
        end
        return
    end

    for r = 1, nrows do
        local line = {}
        for c = 1, ncols do
            local idx
            if opts.list_by_lines then
                idx = (r - 1) * ncols + c
            else
                idx = (c - 1) * nrows + r
            end
            local cell = rendered[idx]
            if cell then
                local is_last = true
                if opts.list_by_lines then
                    is_last = (c == ncols) or (idx == #rendered)
                else
                    is_last = (c == ncols) or ((c * nrows + r) > #rendered)
                end

                if is_last then
                    line[#line + 1] = cell.text
                else
                    local spaces = string.rep(" ", colw - cell.plainw)
                    line[#line + 1] = cell.text .. spaces
                end
            end
        end
        print(table.concat(line))
    end
end

local function print_entries(entries)
    table.sort(entries, cmp_entries)

    if opts.long then
        format_long_rows(entries)
        return
    end

    local use_columns = opts.columns
    if not opts.one and not opts.columns then
        use_columns = isatty_stdout()
    end

    if opts.one then
        for _, e in ipairs(entries) do
            local pfx = ""
            if opts.inode then
                pfx = pfx .. tostring(e.st.ino or 0) .. " "
            end
            if opts.show_blocks then
                pfx = pfx .. tostring(blocks_1k(e.st)) .. " "
            end
            print(pfx .. render_name(e))
        end
    elseif use_columns then
        print_column_layout(entries)
    else
        for _, e in ipairs(entries) do
            local pfx = ""
            if opts.inode then
                pfx = pfx .. tostring(e.st.ino or 0) .. " "
            end
            if opts.show_blocks then
                pfx = pfx .. tostring(blocks_1k(e.st)) .. " "
            end
            print(pfx .. render_name(e))
        end
    end
end

local function scan_dir(path)
    if type(_LISTDIR) ~= "function" then
        return nil, "internal listdir helper unavailable"
    end
    local names, err = _LISTDIR(path)
    if not names then
        return nil, err
    end
    local entries = {}
    for _, name in ipairs(names) do
        if include_name(name) then
            local full = join_path(path, name)
            local e, eerr = build_entry(name, full, name)
            if e then
                entries[#entries + 1] = e
            else
                io.stderr:write("ls: cannot access '" .. full .. "': " .. tostring(eerr) .. "\n")
            end
        end
    end
    return entries
end

local printed_any = false
local function print_header(path)
    if printed_any then
        print("")
    end
    print(path .. ":")
    printed_any = true
end

local function list_path(path, label, show_header)
    local st, err = stat_path(path, opts.follow_links)
    if not st then
        io.stderr:write("ls: cannot access '" .. path .. "': " .. tostring(err) .. "\n")
        return
    end

    if opts.dir_itself or st.kind ~= "dir" then
        local e, eerr = build_entry(label, path, label)
        if not e then
            io.stderr:write("ls: cannot access '" .. path .. "': " .. tostring(eerr) .. "\n")
            return
        end
        print_entries({ e })
        return
    end

    local function recurse_dir(dir_path, header_label)
        local entries, lerr = scan_dir(dir_path)
        if not entries then
            io.stderr:write("ls: cannot open directory '" .. header_label .. "': " .. tostring(lerr) .. "\n")
            return
        end

        if show_header then
            print_header(header_label)
        end

        print_entries(entries)

        if opts.recurse then
            for _, e in ipairs(entries) do
                if e.name ~= "." and e.name ~= ".." and e.lst.kind == "dir" then
                    recurse_dir(e.path, join_path(header_label, e.name))
                end
            end
        end
    end

    recurse_dir(path, label)
end

local show_header = (#targets > 1) or opts.recurse
for _, raw in ipairs(targets) do
    local resolved = resolve_path(raw)
    local label = raw
    if raw == "." then
        label = basename(resolved) ~= "" and raw or resolved
    end
    list_path(resolved, label, show_header)
end
