#!/usr/bin/env sh
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$REPO_ROOT"

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

out="$(printf 'bad\nexit\n' | ./lunacmd 2>&1)"
assert_contains "bad builtin reports load error" "$out" "Failed to load builtin 'bad'"

out="$(printf 'ls /tmp\nexit\n' | ./lunacmd 2>&1)"
assert_not_contains "ls /tmp does not error" "$out" "ls: cannot access '/tmp'"

out="$(printf 'cd /tmp\nls definitely_missing_luna_dir\nexit\n' | ./lunacmd 2>&1)"
assert_contains "ls missing relative path reports absolute target" "$out" "ls: cannot access '/tmp/definitely_missing_luna_dir'"

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

printf "All sanity checks passed.\n"
