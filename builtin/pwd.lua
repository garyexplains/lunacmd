for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: pwd")
        return
    end
end

print(G_CWD or ".")
