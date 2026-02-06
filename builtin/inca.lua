for i = 1, (ARGC or 0) do
    local a_arg = ARGS[i]
    if a_arg == "-h" or a_arg == "--help" then
        print("usage: inca")
        return
    end
end

a = a + 1
