for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: clear")
        return
    end
end

-- Clear screen and move cursor to top-left.
io.write("\27[2J\27[H")
io.flush()
