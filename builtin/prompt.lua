for i = 1, (ARGC or 0) do
    local a = ARGS[i]
    if a == "-h" or a == "--help" then
        print("usage: prompt")
        return
    end
end

local function describe(name, value)
    local t = type(value)
    if t == "nil" then
        print(name .. ": <default>")
    elseif t == "function" then
        print(name .. ": <function>")
    else
        print(name .. ": " .. tostring(value))
    end
end

describe("PROMPT", PROMPT)
describe("PROMPT_CONT", PROMPT_CONT)
