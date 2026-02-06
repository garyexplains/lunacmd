local set_cont = false
local start_idx = 1

if ARGC and ARGC > 0 and ARGS[1] == "--cont" then
    set_cont = true
    start_idx = 2
end

if not ARGC or ARGC < start_idx then
    io.stderr:write("setprompt: usage: setprompt [--cont] TEXT...\n")
    return
end

local parts = {}
for i = start_idx, ARGC do
    parts[#parts + 1] = tostring(ARGS[i] or "")
end

local text = table.concat(parts, " ")
if set_cont then
    PROMPT_CONT = text
else
    PROMPT = text
end
