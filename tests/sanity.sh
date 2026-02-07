#!/usr/bin/env sh
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$REPO_ROOT"
export LUNACMD_NO_RC=1

pass() {
    printf "PASS: %s\n" "$1"
}

fail() {
    printf "FAIL: %s\n" "$1" >&2
    exit 1
}

assert_contains() {
    name="$1"
    haystack="$2"
    needle="$3"
    printf "%s" "$haystack" | grep -F -- "$needle" >/dev/null 2>&1 || fail "$name"
    pass "$name"
}

assert_not_contains() {
    name="$1"
    haystack="$2"
    needle="$3"
    if printf "%s" "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
        fail "$name"
    fi
    pass "$name"
}

assert_line_matches() {
    name="$1"
    haystack="$2"
    regex="$3"
    printf "%s\n" "$haystack" | grep -E "$regex" >/dev/null 2>&1 || fail "$name"
    pass "$name"
}

assert_builtin_help() {
    cmd="$1"

    if [ "$cmd" != "ls" ]; then
        out="$(printf '%s -h\nexit\n' "$cmd" | ./lunacmd 2>&1)"
        assert_contains "$cmd -h prints usage" "$out" "usage: $cmd"
    fi

    out="$(printf '%s --help\nexit\n' "$cmd" | ./lunacmd 2>&1)"
    assert_contains "$cmd --help prints usage" "$out" "usage: $cmd"
}

out="$(printf 'bad\nexit\n' | ./lunacmd 2>&1)"
assert_contains "bad builtin reports load error" "$out" "Failed to load builtin 'bad'"

out="$(printf 'ls /tmp\nexit\n' | ./lunacmd 2>&1)"
assert_not_contains "ls /tmp does not error" "$out" "ls: cannot access '/tmp'"

out="$(printf 'cd /tmp\nls definitely_missing_luna_dir\nexit\n' | ./lunacmd 2>&1)"
assert_contains "ls missing relative path reports absolute target" "$out" "ls: cannot access '/tmp/definitely_missing_luna_dir'"

tmpdir_ls="$(mktemp -d)"
trap 'rm -rf "$tmpdir_ls"' EXIT INT TERM
mkdir -p "$tmpdir_ls/sub"
printf 'visible\n' > "$tmpdir_ls/visible.txt"
printf 'hidden\n' > "$tmpdir_ls/.hidden.txt"
printf '#!/bin/sh\necho ok\n' > "$tmpdir_ls/run.sh"
chmod +x "$tmpdir_ls/run.sh"
printf 'nested\n' > "$tmpdir_ls/sub/nested.txt"

out="$(printf 'ls -a %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_contains "ls -a includes current directory entry" "$out" "."
assert_contains "ls -a includes parent directory entry" "$out" ".."
assert_contains "ls -a includes hidden files" "$out" ".hidden.txt"

out="$(printf 'ls -A %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_contains "ls -A still includes hidden files" "$out" ".hidden.txt"

out="$(printf 'ls -d %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_contains "ls -d lists directory itself" "$out" "$tmpdir_ls"

out="$(printf 'ls -F %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_contains "ls -F marks directories with slash" "$out" "sub/"
assert_contains "ls -F marks executables with star" "$out" "run.sh*"

out="$(printf 'ls -p %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_contains "ls -p marks directories with slash" "$out" "sub/"
assert_not_contains "ls -p does not mark executables with star" "$out" "run.sh*"

out="$(printf 'ls -l -n %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_line_matches "ls -l -n prints long numeric format" "$out" "^[d\\-l][rwx\\-]{9}[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+"

out="$(printf 'ls -R %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_contains "ls -R prints subdirectory header" "$out" "sub:"
assert_contains "ls -R prints nested file" "$out" "nested.txt"

out="$(printf 'ls -l -h %s\nexit\n' "$tmpdir_ls" | ./lunacmd 2>&1)"
assert_line_matches "ls -h enables human-readable sizes" "$out" "[0-9](\\.[0-9])?[BKMGTP]"

out="$(printf 'ls --help\nexit\n' | ./lunacmd 2>&1)"
assert_contains "ls --help prints usage text" "$out" "usage: ls"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM
touch "$tmpdir/lunacmd_test_marker"
out="$(printf 'cd %s\nls\nexit\n' "$tmpdir" | ./lunacmd 2>&1)"
assert_contains "ls defaults to G_CWD after cd" "$out" "lunacmd_test_marker"

out="$(printf 'echo hello world\nexit\n' | ./lunacmd 2>&1)"
assert_contains "echo prints space-joined args" "$out" "hello world"

out="$(printf "echo \"a b\" c\nexit\n" | ./lunacmd 2>&1)"
assert_contains "echo preserves quoted arg grouping" "$out" "a b c"

out="$(printf 'echo\nexit\n' | ./lunacmd 2>&1)"
assert_contains "echo with no args prints blank line before exit" "$out" "echo

exit"

out="$(cat <<'EOF' | ./lunacmd 2>&1
a = 1 + \
2
print(a)
exit
EOF
)"
assert_contains "lua line continuation executes as one chunk" "$out" "3"

out="$(cat <<'EOF' | ./lunacmd 2>&1
echo hello \
world
exit
EOF
)"
assert_contains "builtin command supports line continuation" "$out" "hello world"

out="$(printf 'source hello.lua\nexit\n' | ./lunacmd 2>&1)"
assert_contains "source executes lua file from repo root" "$out" "Hello, world!"

out="$(printf 'source not_a_real_file.lua\nexit\n' | ./lunacmd 2>&1)"
assert_contains "source reports missing file" "$out" "source: cannot load"

tmpdir2="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2"' EXIT INT TERM
cat > "$tmpdir2/source_test.lua" <<'EOF'
print("source_from_tmp")
EOF
out="$(printf 'cd %s\nsource source_test.lua\nexit\n' "$tmpdir2" | ./lunacmd 2>&1)"
assert_contains "source resolves relative paths from G_CWD" "$out" "source_from_tmp"

tmpdir3="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3"' EXIT INT TERM
printf '123456789' > "$tmpdir3/crc.txt"
out="$(printf 'cksum %s/crc.txt\nexit\n' "$tmpdir3" | ./lunacmd 2>&1)"
assert_contains "cksum computes known crc32 vector" "$out" "cbf43926 9 $tmpdir3/crc.txt"

out="$(printf 'cksum\nexit\n' | ./lunacmd 2>&1)"
assert_contains "cksum reports missing operand" "$out" "cksum: missing file operand"

out="$(printf 'date +%%Y\nexit\n' | ./lunacmd 2>&1)"
assert_line_matches "date supports +FORMAT year output" "$out" "^[0-9]{4}$"

out="$(printf 'date -u +%%H\nexit\n' | ./lunacmd 2>&1)"
assert_line_matches "date supports -u with format" "$out" "^[0-9]{2}$"

out="$(printf 'date --bad\nexit\n' | ./lunacmd 2>&1)"
assert_contains "date reports unsupported args" "$out" "date: unsupported argument: --bad"

tmpdir4="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4"' EXIT INT TERM
printf 'from_src\n' > "$tmpdir4/src.txt"
printf 'old_dst\n' > "$tmpdir4/dst.txt"
mkdir -p "$tmpdir4/tree/sub"
printf 'nested\n' > "$tmpdir4/tree/sub/file.txt"

out="$(printf 'cp %s/src.txt %s/copied.txt\ncat %s/copied.txt\nexit\n' "$tmpdir4" "$tmpdir4" "$tmpdir4" | ./lunacmd 2>&1)"
assert_contains "cp copies a file" "$out" "from_src"

out="$(printf 'cp -f %s/src.txt %s/dst.txt\ncat %s/dst.txt\nexit\n' "$tmpdir4" "$tmpdir4" "$tmpdir4" | ./lunacmd 2>&1)"
assert_contains "cp -f overwrites destination" "$out" "from_src"

out="$(printf 'cp -R %s/tree %s/tree_copy\ncat %s/tree_copy/sub/file.txt\nexit\n' "$tmpdir4" "$tmpdir4" "$tmpdir4" | ./lunacmd 2>&1)"
assert_contains "cp -R copies directories recursively" "$out" "nested"

out="$(printf 'cp -v %s/src.txt %s/verbose_copy.txt\nexit\n' "$tmpdir4" "$tmpdir4" | ./lunacmd 2>&1)"
assert_contains "cp -v prints verbose copy output" "$out" "->"

tmpdir5="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5"' EXIT INT TERM
printf 'mv_src\n' > "$tmpdir5/a.txt"
printf 'old_value\n' > "$tmpdir5/b.txt"
mkdir -p "$tmpdir5/mvdir/sub"
printf 'mv_nested\n' > "$tmpdir5/mvdir/sub/file.txt"

out="$(printf 'mv %s/a.txt %s/a2.txt\ncat %s/a2.txt\nexit\n' "$tmpdir5" "$tmpdir5" "$tmpdir5" | ./lunacmd 2>&1)"
assert_contains "mv renames a file" "$out" "mv_src"

out="$(printf 'mv -f %s/a2.txt %s/b.txt\ncat %s/b.txt\nexit\n' "$tmpdir5" "$tmpdir5" "$tmpdir5" | ./lunacmd 2>&1)"
assert_contains "mv -f overwrites destination" "$out" "mv_src"

out="$(printf 'mv %s/mvdir %s/mvdir2\ncat %s/mvdir2/sub/file.txt\nexit\n' "$tmpdir5" "$tmpdir5" "$tmpdir5" | ./lunacmd 2>&1)"
assert_contains "mv moves directories" "$out" "mv_nested"

printf 'verbose_mv\n' > "$tmpdir5/vsrc.txt"
out="$(printf 'mv -v %s/vsrc.txt %s/vdst.txt\nexit\n' "$tmpdir5" "$tmpdir5" | ./lunacmd 2>&1)"
assert_contains "mv -v prints verbose move output" "$out" "->"

tmpdir6="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6"' EXIT INT TERM
printf 'abcdefghij\n' > "$tmpdir6/fold1.txt"
printf 'alpha beta gamma\n' > "$tmpdir6/fold2.txt"

out="$(printf 'fold -w 4 %s/fold1.txt\nexit\n' "$tmpdir6" | ./lunacmd 2>&1)"
assert_contains "fold hard-wraps by width" "$out" "abcd"
assert_contains "fold hard-wraps by width second line" "$out" "efgh"
assert_contains "fold hard-wraps by width tail" "$out" "ij"

out="$(printf 'fold -s -w 7 %s/fold2.txt\nexit\n' "$tmpdir6" | ./lunacmd 2>&1)"
assert_contains "fold -s breaks on spaces" "$out" "alpha"
assert_contains "fold -s keeps whole words when possible" "$out" "beta"
assert_contains "fold -s emits trailing word" "$out" "gamma"

tmpdir7="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7"' EXIT INT TERM

out="$(printf 'mkdir %s/simple_dir\ncd %s/simple_dir\npwd\nexit\n' "$tmpdir7" "$tmpdir7" | ./lunacmd 2>&1)"
assert_contains "mkdir creates a directory" "$out" "$tmpdir7/simple_dir"

out="$(printf 'mkdir -p %s/n1/n2/n3\ncd %s/n1/n2/n3\npwd\nexit\n' "$tmpdir7" "$tmpdir7" | ./lunacmd 2>&1)"
assert_contains "mkdir -p creates nested directories" "$out" "$tmpdir7/n1/n2/n3"

tmpdir8="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8"' EXIT INT TERM
printf 'rm_data\n' > "$tmpdir8/rm_a.txt"
printf 'keep_data\n' > "$tmpdir8/rm_b.txt"

out="$(printf 'rm %s/rm_a.txt\ncat %s/rm_a.txt\nexit\n' "$tmpdir8" "$tmpdir8" | ./lunacmd 2>&1)"
assert_contains "rm removes regular files" "$out" "cat: cannot open '$tmpdir8/rm_a.txt'"

out="$(printf 'rm -i %s/rm_b.txt\nn\n' "$tmpdir8" | ./lunacmd 2>&1)"
assert_contains "rm -i prompts before remove" "$out" "rm: remove '$tmpdir8/rm_b.txt'?"
assert_contains "rm -i keeps file when declined" "$(cat "$tmpdir8/rm_b.txt")" "keep_data"

out="$(printf 'rm -f %s/rm_b.txt\nrm -f %s/does_not_exist.txt\nexit\n' "$tmpdir8" "$tmpdir8" | ./lunacmd 2>&1)"
assert_not_contains "rm -f does not prompt" "$out" "rm: remove '$tmpdir8/rm_b.txt'?"
assert_not_contains "rm -f suppresses missing-file errors" "$out" "No such file or directory"

tmpdir_rmdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir_rmdir"' EXIT INT TERM
mkdir -p "$tmpdir_rmdir/empty"
mkdir -p "$tmpdir_rmdir/nonempty"
printf 'x\n' > "$tmpdir_rmdir/nonempty/file.txt"
mkdir -p "$tmpdir_rmdir/p/a/b"

out="$(printf 'rmdir %s/empty\ncd %s/empty\nexit\n' "$tmpdir_rmdir" "$tmpdir_rmdir" | ./lunacmd 2>&1)"
assert_contains "rmdir removes empty directory" "$out" "cd: no such file or directory"

out="$(printf 'rmdir %s/nonempty\nexit\n' "$tmpdir_rmdir" | ./lunacmd 2>&1)"
assert_contains "rmdir rejects non-empty directory" "$out" "Directory not empty"

out="$(printf 'rmdir -p %s/p/a/b\ncd %s/p\nexit\n' "$tmpdir_rmdir" "$tmpdir_rmdir" | ./lunacmd 2>&1)"
assert_contains "rmdir -p removes parent chain" "$out" "cd: no such file or directory"

out="$(printf 'sleep 0.01s 0.001m 0h 0d\necho slept\nexit\n' | ./lunacmd 2>&1)"
assert_contains "sleep supports summed durations with suffixes" "$out" "slept"

out="$(printf 'sleep nope\nexit\n' | ./lunacmd 2>&1)"
assert_contains "sleep reports invalid interval" "$out" "sleep: invalid time interval 'nope'"

tmpdir9="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9"' EXIT INT TERM
printf 'one two\nthree\n\n' > "$tmpdir9/wc.txt"

out="$(printf 'wc %s/wc.txt\nexit\n' "$tmpdir9" | ./lunacmd 2>&1)"
assert_contains "wc default counts lines words bytes" "$out" "3        3       15 $tmpdir9/wc.txt"

out="$(printf 'wc -m %s/wc.txt\nexit\n' "$tmpdir9" | ./lunacmd 2>&1)"
assert_contains "wc -m counts characters" "$out" "15 $tmpdir9/wc.txt"

out="$(printf 'wc -L %s/wc.txt\nexit\n' "$tmpdir9" | ./lunacmd 2>&1)"
assert_contains "wc -L reports longest line length" "$out" "7 $tmpdir9/wc.txt"

tmpdir10="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10"' EXIT INT TERM
printf 'line_from_stdin\n' > "$tmpdir10/in.txt"

out="$(printf 'echo redir_one :> %s/out.txt\ncat %s/out.txt\nexit\n' "$tmpdir10" "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "stdout redirection writes file" "$out" "redir_one"

out="$(printf 'echo first :> %s/append.txt\necho second :>> %s/append.txt\ncat %s/append.txt\nexit\n' "$tmpdir10" "$tmpdir10" "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "stdout append redirection keeps first line" "$out" "first"
assert_contains "stdout append redirection appends second line" "$out" "second"

out="$(printf 'rm %s/no_such_file.txt 2:> %s/err.txt\ncat %s/err.txt\nexit\n' "$tmpdir10" "$tmpdir10" "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "stderr redirection captures error output" "$out" "No such file or directory"

out="$(printf 'rm %s/no_such_file2.txt :> %s/both.txt 2:>&1\ncat %s/both.txt\nexit\n' "$tmpdir10" "$tmpdir10" "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "stderr to stdout redirection works" "$out" "No such file or directory"

out="$(printf 'exec cat :< %s/in.txt\nexit\n' "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "stdin redirection feeds command input" "$out" "line_from_stdin"

out="$(printf 'echo hi :| exec cat\nexit\n' | ./lunacmd 2>&1)"
assert_contains "pipeline executes with lunacmd pipe syntax" "$out" "hi"

out="$(printf 'echo catstdin :| cat\nexit\n' | ./lunacmd 2>&1)"
assert_contains "cat reads stdin when used in pipeline" "$out" "catstdin"

out="$(printf 'echo one two three :| wc -w\nexit\n' | ./lunacmd 2>&1)"
assert_contains "wc reads stdin in pipeline" "$out" "3 -"

out="$(printf 'echo abcdef :| fold -w 3\nexit\n' | ./lunacmd 2>&1)"
assert_contains "fold reads stdin in pipeline first chunk" "$out" "abc"
assert_contains "fold reads stdin in pipeline second chunk" "$out" "def"

out="$(printf 'lunabuffer clear all\necho mem_line :> :@mem\ncat :< :@mem\nexit\n' | ./lunacmd 2>&1)"
assert_contains "mem buffer captures stdout redirection" "$out" "mem_line"

out="$(printf 'lunabuffer clear all\necho one :> :@mem\necho two :>> :@mem\ncat :< :@mem\nexit\n' | ./lunacmd 2>&1)"
assert_contains "mem buffer supports append redirection first line" "$out" "one"
assert_contains "mem buffer supports append redirection second line" "$out" "two"

out="$(printf 'rm /definitely_no_luna_file 2:> :@mem\ncat :< :@mem\nexit\n' | ./lunacmd 2>&1)"
assert_contains "mem buffer captures stderr redirection" "$out" "No such file or directory"

out="$(printf 'lunabuffer clear mem\necho hello_buffer :> :@mem\nexec grep hello :< :@mem\nexit\n' | ./lunacmd 2>&1)"
assert_contains "mem buffer can feed stdin via :<" "$out" "hello_buffer"

out="$(printf 'lunabuffer clear all\necho file_line :> :@file\ncat :< :@file\nexit\n' | ./lunacmd 2>&1)"
assert_contains "file buffer captures stdout redirection" "$out" "file_line"

tmpdir_buf="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir_rmdir" "$tmpdir_buf"' EXIT INT TERM
out="$(printf 'lunabuffer clear mem\nlunabuffer size 10\nexec printf 123456789012345 :> :@mem\nwc -c :< :@mem\nlunabuffer save mem %s/mem.bin\nwc -c %s/mem.bin\nexit\n' "$tmpdir_buf" "$tmpdir_buf" | ./lunacmd 2>&1)"
assert_contains "lunabuffer size applies truncation policy" "$out" "10 -"
assert_contains "lunabuffer save writes memory buffer to file" "$out" "10 $tmpdir_buf/mem.bin"

out="$(printf ':! echo legacy > %s/legacy.txt\ncat %s/legacy.txt\nexit\n' "$tmpdir10" "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "legacy symbols work only with :! prefix" "$out" "legacy"

out="$(printf 'a=1; b=2; if a < b then print(\"lua_cmp_ok\") end\nexit\n' | ./lunacmd 2>&1)"
assert_contains "lua comparison operators stay valid in default mode" "$out" "lua_cmp_ok"

out="$(printf 'ls > %s/legacy_oops.txt\nexit\n' "$tmpdir10" | ./lunacmd 2>&1)"
assert_contains "legacy redirect without :! gives helpful parse error" "$out" "legacy operator '>' requires ':!' prefix"

out="$(printf 'setprompt LUNA>\nprompt\nexit\n' | ./lunacmd 2>&1)"
assert_contains "setprompt updates PROMPT string" "$out" "PROMPT: LUNA>"

out="$(printf 'PROMPT=function() return G_CWD end\ncd /tmp\nprint("PROMPT_VALUE=" .. PROMPT())\nexit\n' | ./lunacmd 2>&1)"
assert_contains "prompt function can use current G_CWD" "$out" "PROMPT_VALUE=/tmp"

out="$(printf 'PROMPT=function() error("boom") end\necho ok\nexit\n' | ./lunacmd 2>&1)"
assert_contains "prompt function failure falls back with warning" "$out" "Prompt error (PROMPT):"
assert_contains "prompt fallback still allows execution" "$out" "ok"

out="$(printf 'PROMPT_CONT="++ "\nprompt\nexit\n' | ./lunacmd 2>&1)"
assert_contains "custom continuation prompt can be configured" "$out" "PROMPT_CONT: ++ "

out="$(printf 'alias less = more\necho alias_more_line :| less\nexit\n' | ./lunacmd 2>&1)"
assert_contains "alias supports command replacement" "$out" "alias_more_line"

tmpdir15="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10" "$tmpdir11" "$tmpdir12" "$tmpdir13" "$tmpdir14" "$tmpdir15"' EXIT INT TERM
printf 'zz_alias_marker\n' > "$tmpdir15/marker.txt"
out="$(printf 'alias lstmp = ls %s\nlstmp\nexit\n' "$tmpdir15" | ./lunacmd 2>&1)"
assert_contains "alias supports value with arguments" "$out" "marker.txt"

tmpdir16="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10" "$tmpdir11" "$tmpdir12" "$tmpdir13" "$tmpdir14" "$tmpdir15" "$tmpdir16"' EXIT INT TERM
cat > "$tmpdir16/.lunacmd.lua" <<'EOF'
alias("rcalias", "echo from_rc_alias")
EOF
out="$(printf 'rcalias\nexit\n' | HOME="$tmpdir16" LUNACMD_NO_RC= ./lunacmd 2>&1)"
assert_contains "aliases can be defined from ~/.lunacmd.lua via alias()" "$out" "from_rc_alias"

tmpdir11="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10" "$tmpdir11"' EXIT INT TERM
mkdir -p "$tmpdir11/.lunacmd/builtin"
cat > "$tmpdir11/.lunacmd/builtin/ubcmd.lua" <<'EOF'
print("from_user_builtin")
EOF
cat > "$tmpdir11/.lunacmd/builtin/echo.lua" <<'EOF'
print("USER_ECHO_OVERRIDE")
EOF

out="$(printf 'ubcmd\nwhich ubcmd\ntype ubcmd\nexit\n' | HOME="$tmpdir11" ./lunacmd 2>&1)"
assert_contains "user builtin executes from ~/.lunacmd/builtin" "$out" "from_user_builtin"
assert_contains "which reports user builtin path" "$out" "$tmpdir11/.lunacmd/builtin/ubcmd.lua"
assert_contains "type reports user builtin kind" "$out" "ubcmd is a user builtin"

out="$(printf 'echo hello\nexit\n' | HOME="$tmpdir11" ./lunacmd 2>&1)"
assert_contains "core builtin takes precedence over user duplicate" "$out" "hello"
assert_not_contains "core precedence blocks user override by default" "$out" "USER_ECHO_OVERRIDE"

out="$(printf 'ubcmd\nexit\n' | HOME="$tmpdir11" LUNACMD_NO_USER_BUILTINS=1 ./lunacmd 2>&1)"
assert_contains "LUNACMD_NO_USER_BUILTINS disables user builtin lookup" "$out" "Lua error:"

tmpdir12="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10" "$tmpdir11" "$tmpdir12"' EXIT INT TERM
printf 'ABC\n' > "$tmpdir12/h.txt"

out="$(printf 'hexdump %s/h.txt\nexit\n' "$tmpdir12" | ./lunacmd 2>&1)"
assert_contains "hexdump default includes offset" "$out" "00000000"
assert_contains "hexdump default includes hex bytes" "$out" "41 42 43 0a"
assert_contains "hexdump default includes ascii panel" "$out" "|ABC."

out="$(printf 'hexdump -x %s/h.txt\nexit\n' "$tmpdir12" | ./lunacmd 2>&1)"
assert_contains "hexdump -x outputs raw hex" "$out" "41 42 43 0a"

out="$(printf 'echo ABC :| hexdump -x\nexit\n' | ./lunacmd 2>&1)"
assert_contains "hexdump reads stdin in pipeline" "$out" "41 42 43 0a"

for cmd in \
    alias cat cd cksum clear cp date echo exec fold head hexdump inca ls lunabuffer mkdir more mv prompt pwd rm rmdir setprompt sleep source type wc which
do
    assert_builtin_help "$cmd"
done

tmpdir13="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10" "$tmpdir11" "$tmpdir12" "$tmpdir13"' EXIT INT TERM
printf 'm1\nm2\n' > "$tmpdir13/more.txt"

out="$(printf 'more %s/more.txt\nexit\n' "$tmpdir13" | ./lunacmd 2>&1)"
assert_contains "more prints file content in non-interactive mode" "$out" "m1"
assert_contains "more prints full file content in non-interactive mode" "$out" "m2"

out="$(printf 'echo piped_more :| more\nexit\n' | ./lunacmd 2>&1)"
assert_contains "more reads stdin in pipeline" "$out" "piped_more"

tmpdir14="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3" "$tmpdir4" "$tmpdir5" "$tmpdir6" "$tmpdir7" "$tmpdir8" "$tmpdir9" "$tmpdir10" "$tmpdir11" "$tmpdir12" "$tmpdir13" "$tmpdir14"' EXIT INT TERM
cat > "$tmpdir14/a.txt" <<'EOF'
l1
l2
l3
l4
l5
l6
l7
l8
l9
l10
l11
EOF
printf 'ABCDEFGH' > "$tmpdir14/b.bin"

out="$(printf 'head %s/a.txt\nexit\n' "$tmpdir14" | ./lunacmd 2>&1)"
assert_contains "head default prints first 10 lines" "$out" "l10"
assert_not_contains "head default does not print line 11" "$out" "l11"

out="$(printf 'head -n 3 %s/a.txt\nexit\n' "$tmpdir14" | ./lunacmd 2>&1)"
assert_contains "head -n prints first N lines" "$out" "l3"
assert_not_contains "head -n excludes later lines" "$out" "l4"

out="$(printf 'head -c 1k %s/b.bin\nexit\n' "$tmpdir14" | ./lunacmd 2>&1)"
assert_contains "head -c with suffix prints bytes" "$out" "ABCDEFGH"

out="$(printf 'head %s/a.txt %s/a.txt\nexit\n' "$tmpdir14" "$tmpdir14" | ./lunacmd 2>&1)"
assert_contains "head prints headers for multiple files by default" "$out" "==> $tmpdir14/a.txt <=="

out="$(printf 'head -q %s/a.txt %s/a.txt\nexit\n' "$tmpdir14" "$tmpdir14" | ./lunacmd 2>&1)"
assert_not_contains "head -q suppresses headers" "$out" "==> $tmpdir14/a.txt <=="

out="$(printf 'head -v %s/a.txt\nexit\n' "$tmpdir14" | ./lunacmd 2>&1)"
assert_contains "head -v forces headers" "$out" "==> $tmpdir14/a.txt <=="

out="$(printf 'echo stdin_line :| head -n 1\nexit\n' | ./lunacmd 2>&1)"
assert_contains "head reads stdin in pipeline" "$out" "stdin_line"

printf "All sanity checks passed.\n"
