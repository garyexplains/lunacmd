# Lua One-Liner Cheatsheet (lunacmd)

Useful Lua-first one-liners you can run directly in `lunacmd`.

## Paths and Files

1. Parent directory of current path:
```lua
print((G_CWD:gsub("/[^/]*$", "")) ~= "" and (G_CWD:gsub("/[^/]*$", "")) or "/")
```

2. Last path component (basename):
```lua
print((G_CWD:match("([^/]+)$")) or G_CWD)
```

3. Home directory:
```lua
print(os.getenv("HOME") or "")
```

4. Check if file exists:
```lua
print(io.open("README", "rb") and "yes" or "no")
```

5. Read full file:
```lua
local f=io.open("README","rb"); print(f and (f:read("*a")) or "open failed"); if f then f:close() end
```

6. Print first line of file:
```lua
local f=io.open("README","rb"); print(f and (f:read("*l") or "") or "open failed"); if f then f:close() end
```

7. Count file bytes:
```lua
local f=io.open("README","rb"); local s=f and f:read("*a") or ""; if f then f:close() end; print(#s)
```

8. List files in current directory:
```lua
for _,n in ipairs(_LISTDIR(G_CWD) or {}) do print(n) end
```

9. List only `.lua` files:
```lua
for _,n in ipairs(_LISTDIR(G_CWD) or {}) do if n:match("%.lua$") then print(n) end end
```

10. Resolve command source metadata:
```lua
local r=_RESOLVE_CMD("ls"); print(r.kind, r.path or "")
```

## Strings and Text

11. Uppercase text:
```lua
print(("hello lunacmd"):upper())
```

12. Lowercase text:
```lua
print(("HELLO LUNACMD"):lower())
```

13. Trim leading/trailing whitespace:
```lua
local s="  hi there  "; print((s:gsub("^%s+",""):gsub("%s+$","")))
```

14. Replace all spaces with underscores:
```lua
print(("hello lua world"):gsub("%s+","_"))
```

15. Split words:
```lua
for w in ("one two three"):gmatch("%S+") do print(w) end
```

16. Count words in a string:
```lua
local n=0; for _ in ("one two three"):gmatch("%S+") do n=n+1 end; print(n)
```

17. Reverse a string:
```lua
print(("lunacmd"):reverse())
```

18. Test regex-like pattern:
```lua
print(("notes.txt"):match("%.txt$") and "txt" or "not txt")
```

19. Join array with delimiter:
```lua
print(table.concat({"a","b","c"}, ":"))
```

20. Escape single quotes for shell-like strings:
```lua
print(("a'b'c"):gsub("'", "'\\''"))
```

## Tables and Data

21. Print table keys:
```lua
for k,_ in pairs({a=1,b=2,c=3}) do print(k) end
```

22. Sort and print values:
```lua
local t={5,1,9,2}; table.sort(t); for _,v in ipairs(t) do print(v) end
```

23. Build frequency map:
```lua
local f={}; for w in ("a b a c b a"):gmatch("%S+") do f[w]=(f[w] or 0)+1 end; for k,v in pairs(f) do print(k,v) end
```

24. Deep-ish print with `pairs`:
```lua
local t={name="luna",v=1}; for k,v in pairs(t) do print(k,v) end
```

25. Filter array:
```lua
local t={1,2,3,4,5}; local o={}; for _,v in ipairs(t) do if v%2==1 then o[#o+1]=v end end; print(table.concat(o,","))
```

26. Map array:
```lua
local t={1,2,3}; for i,v in ipairs(t) do t[i]=v*v end; print(table.concat(t,","))
```

27. Remove duplicates:
```lua
local in_t={"a","b","a","c"}; local seen,o={},{}; for _,v in ipairs(in_t) do if not seen[v] then seen[v]=true; o[#o+1]=v end end; print(table.concat(o,","))
```

28. Safe default:
```lua
local cfg={}; print(cfg.timeout or 30)
```

29. Check membership in set:
```lua
local set={rm=true,mv=true}; print(set["rm"] and "yes" or "no")
```

30. Clone simple array:
```lua
local a={1,2,3}; local b={table.unpack(a)}; print(table.concat(b,","))
```

## Numbers and Math

31. Round to nearest int:
```lua
local x=3.6; print(math.floor(x+0.5))
```

32. Clamp number:
```lua
local x,min,max=120,0,100; print(math.max(min, math.min(max, x)))
```

33. Random integer range:
```lua
math.randomseed(os.time()); print(math.random(1,100))
```

34. Hex of number:
```lua
print(string.format("0x%X", 3735928559))
```

35. Binary-ish bit ops:
```lua
print((0xF0 & 0x0F), (0xF0 | 0x0F), (0xF0 ~ 0x0F))
```

36. Byte size pretty print:
```lua
local n=1536000; local u={"B","KB","MB","GB"}; local i=1; while n>=1024 and i<#u do n=n/1024; i=i+1 end; print(string.format("%.2f %s",n,u[i]))
```

37. Sum values:
```lua
local s=0; for _,v in ipairs({1,2,3,4}) do s=s+v end; print(s)
```

38. Average values:
```lua
local t={3,5,7}; local s=0; for _,v in ipairs(t) do s=s+v end; print(#t>0 and s/#t or 0)
```

39. Min/max in array:
```lua
local t={9,2,7,4}; table.sort(t); print(t[1], t[#t])
```

40. Modulo-based wrap index:
```lua
local i,n=14,5; print(((i-1)%n)+1)
```

## Dates, Time, and Prompt Helpers

41. Local timestamp:
```lua
print(os.date("%Y-%m-%d %H:%M:%S"))
```

42. UTC timestamp:
```lua
print(os.date("!%Y-%m-%dT%H:%M:%SZ"))
```

43. Unix epoch now:
```lua
print(os.time())
```

44. Seconds since midnight:
```lua
local t=os.date("*t"); print(t.hour*3600 + t.min*60 + t.sec)
```

45. Human status from LAST_STATUS:
```lua
print((LAST_STATUS or 0)==0 and "ok" or ("err:"..tostring(LAST_STATUS)))
```

46. Prompt showing cwd + status:
```lua
PROMPT=function() return string.format("[%s] %s > ", tostring(LAST_STATUS or 0), G_CWD or ".") end
```

47. Colored prompt (ANSI):
```lua
PROMPT=function() return "\27[32m"..(G_CWD or ".").."\27[0m > " end
```

48. Custom continuation prompt:
```lua
PROMPT_CONT="... "
```

49. Show current command resolution context:
```lua
print("CMD="..tostring(CMD), "SRC="..tostring(CMD_SOURCE), "PATH="..tostring(CMD_PATH))
```

50. One-liner quick help for builtins:
```lua
for _,n in ipairs(_LISTDIR("builtin") or {}) do if n:match("%.lua$") then print(n:gsub("%.lua$","")) end end
```
