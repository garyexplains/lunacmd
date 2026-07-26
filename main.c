#define _POSIX_C_SOURCE 200809L

/*
 * To compile:
 * gcc -o lunacmd main.c -llua -Llua/src/ -Ilua/src/ -lm -lreadline
 *
 */

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <readline/history.h>
#include <readline/readline.h>
#include <limits.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#ifdef __APPLE__
static HIST_ENTRY **history_list(void) {
    static HIST_ENTRY **list = NULL;
    static int allocated_count = 0;
    int i;
    if (list) {
        for (i = 0; i < allocated_count; i++) {
            if (list[i]) {
                if (list[i]->line) {
                    free((void *)list[i]->line);
                }
                free(list[i]);
            }
        }
        free(list);
    }
    list = malloc((history_length + 1) * sizeof(HIST_ENTRY *));
    allocated_count = history_length;
    if (!list) return NULL;
    for (i = 0; i < history_length; i++) {
        HIST_ENTRY *e = history_get(history_base + i);
        list[i] = malloc(sizeof(HIST_ENTRY));
        if (list[i] && e) {
            list[i]->line = e->line ? strdup(e->line) : NULL;
            list[i]->data = e->data;
        } else if (list[i]) {
            list[i]->line = NULL;
            list[i]->data = NULL;
        }
    }
    list[history_length] = NULL;
    return list;
}
#endif

#ifndef DEFAULT_BUILTIN_DIR
#define DEFAULT_BUILTIN_DIR "/usr/local/share/lunacmd/builtin"
#endif

/* A static variable for holding the line. */
static char *line_read = (char *)NULL;

#define MAX_PARSE_ERR 256

typedef enum TokenType {
    TOKEN_EOF = 0,
    TOKEN_WORD,
    TOKEN_PIPE,
    TOKEN_LUA_PIPE,
    TOKEN_REDIR_IN,
    TOKEN_REDIR_OUT,
    TOKEN_REDIR_OUT_APPEND,
    TOKEN_REDIR_ERR_OUT,
    TOKEN_REDIR_ERR_OUT_APPEND,
    TOKEN_REDIR_ERR_TO_OUT,
} TokenType;

typedef enum PipeType {
    PIPE_TEXT = 0,
    PIPE_LUA,
} PipeType;

typedef enum ParseSyntaxMode {
    SYNTAX_LUNA = 0,
    SYNTAX_LEGACY,
} ParseSyntaxMode;

typedef struct Token {
    TokenType type;
    char *text;
} Token;

typedef enum RedirType {
    REDIR_IN = 0,
    REDIR_OUT,
    REDIR_OUT_APPEND,
    REDIR_ERR_OUT,
    REDIR_ERR_OUT_APPEND,
    REDIR_ERR_TO_OUT,
} RedirType;

typedef struct Redirection {
    RedirType type;
    char *target;
} Redirection;

typedef struct CommandNode {
    int argc;
    char **argv;
    int redir_count;
    Redirection *redirs;
} CommandNode;

typedef struct PipelineNode {
    int command_count;
    CommandNode *commands;
    int pipe_count;
    PipeType *pipes;
} PipelineNode;

typedef struct CommandAst {
    PipelineNode pipeline;
} CommandAst;

typedef struct LunaBufferState {
    char mem_path[PATH_MAX];
    char file_path[PATH_MAX];
    size_t mem_max;
    int initialized;
} LunaBufferState;

typedef enum JobState {
    JOB_RUNNING = 0,
    JOB_STOPPED,
} JobState;

typedef struct Job {
    int id;
    pid_t pgid;
    char *cmdline;
    JobState state;
} Job;

static int next_token(
    const char **input, ParseSyntaxMode mode, Token *out, char *err, size_t err_size);
static char *dup_cstr(const char *s);
static void free_token(Token *token);
static LunaBufferState g_luna_buffer = {{0}, {0}, 16 * 1024, 0};
static char g_history_path[PATH_MAX];
static int g_history_path_ready = 0;
static Job *g_jobs = NULL;
static int g_job_count = 0;
static int g_next_job_id = 1;
static pid_t g_shell_pgid = 0;
static int g_preview_mode = 0;

static int expand_builtin_globs(lua_State *L, char ***argv_ptr, int *argc_ptr, char *err, size_t err_size);

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int is_env_enabled(const char *name) {
    const char *v = getenv(name);
    return v && *v;
}

static int ensure_parent_dir(const char *path) {
    struct stat st;

    if (stat(path, &st) == 0) {
        return S_ISDIR(st.st_mode) ? 1 : 0;
    }
    if (mkdir(path, 0700) == 0) {
        return 1;
    }
    if (errno == EEXIST) {
        return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
    }
    return 0;
}

static int file_size_bytes(const char *path, size_t *out) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return 0;
    }
    if (!S_ISREG(st.st_mode)) {
        return 0;
    }
    if (out) {
        *out = (size_t)st.st_size;
    }
    return 1;
}

static int truncate_file_to(const char *path, size_t max_size) {
    int fd = open(path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) {
        return 0;
    }
    if (ftruncate(fd, (off_t)max_size) != 0) {
        close(fd);
        return 0;
    }
    close(fd);
    return 1;
}

static int clamp_memory_buffer(void) {
    size_t sz = 0;
    if (!file_size_bytes(g_luna_buffer.mem_path, &sz)) {
        int fd = open(g_luna_buffer.mem_path, O_WRONLY | O_CREAT, 0600);
        if (fd >= 0) {
            close(fd);
        }
        return 1;
    }
    if (sz <= g_luna_buffer.mem_max) {
        return 1;
    }
    return truncate_file_to(g_luna_buffer.mem_path, g_luna_buffer.mem_max);
}

static int init_luna_buffers(void) {
    const char *home = getenv("HOME");
    int fd;

    if (g_luna_buffer.initialized) {
        return 1;
    }

    if (snprintf(
            g_luna_buffer.mem_path, sizeof(g_luna_buffer.mem_path), "/tmp/lunacmd-mem-%ld.buf", (long)getpid())
        >= (int)sizeof(g_luna_buffer.mem_path)) {
        return 0;
    }
    fd = open(g_luna_buffer.mem_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        return 0;
    }
    close(fd);

    if (home && *home) {
        char dir_path[PATH_MAX];
        if (snprintf(dir_path, sizeof(dir_path), "%s/.lunacmd", home) < (int)sizeof(dir_path)
            && ensure_parent_dir(dir_path)
            && snprintf(g_luna_buffer.file_path, sizeof(g_luna_buffer.file_path), "%s/buffer", dir_path)
                   < (int)sizeof(g_luna_buffer.file_path)) {
            fd = open(g_luna_buffer.file_path, O_RDWR | O_CREAT, 0600);
            if (fd >= 0) {
                close(fd);
                g_luna_buffer.initialized = 1;
                return 1;
            }
        }
    }

    if (snprintf(
            g_luna_buffer.file_path, sizeof(g_luna_buffer.file_path), "/tmp/lunacmd-file-%ld.buf", (long)getuid())
        >= (int)sizeof(g_luna_buffer.file_path)) {
        return 0;
    }
    fd = open(g_luna_buffer.file_path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) {
        return 0;
    }
    close(fd);

    g_luna_buffer.initialized = 1;
    return 1;
}

static int init_history_path(void) {
    const char *home = getenv("HOME");
    int fd;

    if (g_history_path_ready) {
        return 1;
    }

    if (home && *home) {
        char dir_path[PATH_MAX];
        if (snprintf(dir_path, sizeof(dir_path), "%s/.lunacmd", home) < (int)sizeof(dir_path)
            && ensure_parent_dir(dir_path)
            && snprintf(g_history_path, sizeof(g_history_path), "%s/history", dir_path)
                   < (int)sizeof(g_history_path)) {
            fd = open(g_history_path, O_RDWR | O_CREAT, 0600);
            if (fd >= 0) {
                close(fd);
                g_history_path_ready = 1;
                return 1;
            }
        }
    }

    if (snprintf(g_history_path, sizeof(g_history_path), "/tmp/lunacmd-history-%ld", (long)getuid())
        >= (int)sizeof(g_history_path)) {
        return 0;
    }
    fd = open(g_history_path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) {
        return 0;
    }
    close(fd);

    g_history_path_ready = 1;
    return 1;
}

static int is_buffer_target_word(const char *target, const char **path_out, int *is_mem_out) {
    if (!target) {
        return 0;
    }
    if (strcmp(target, ":@mem") == 0) {
        if (!init_luna_buffers()) {
            return 0;
        }
        if (path_out) {
            *path_out = g_luna_buffer.mem_path;
        }
        if (is_mem_out) {
            *is_mem_out = 1;
        }
        return 1;
    }
    if (strcmp(target, ":@file") == 0) {
        if (!init_luna_buffers()) {
            return 0;
        }
        if (path_out) {
            *path_out = g_luna_buffer.file_path;
        }
        if (is_mem_out) {
            *is_mem_out = 0;
        }
        return 1;
    }
    return 0;
}

static int path_is_readable_file(const char *path) {
    struct stat st;
    if (access(path, R_OK) != 0) {
        return 0;
    }
    if (stat(path, &st) != 0) {
        return 0;
    }
    return S_ISREG(st.st_mode) ? 1 : 0;
}

static Job *find_job_by_id(int id) {
    int i;
    for (i = 0; i < g_job_count; i++) {
        if (g_jobs[i].id == id) {
            return &g_jobs[i];
        }
    }
    return NULL;
}

static void remove_job_index(int idx) {
    int i;
    if (idx < 0 || idx >= g_job_count) {
        return;
    }
    free(g_jobs[idx].cmdline);
    for (i = idx; i + 1 < g_job_count; i++) {
        g_jobs[i] = g_jobs[i + 1];
    }
    g_job_count--;
    if (g_job_count == 0) {
        g_next_job_id = 1;
        free(g_jobs);
        g_jobs = NULL;
    } else {
        Job *next = realloc(g_jobs, sizeof(Job) * (size_t)g_job_count);
        if (next) {
            g_jobs = next;
        }
    }
}

static int add_job(pid_t pgid, const char *cmdline, JobState state) {
    Job *next;
    next = realloc(g_jobs, sizeof(Job) * (size_t)(g_job_count + 1));
    if (!next) {
        return -1;
    }
    g_jobs = next;
    g_jobs[g_job_count].id = g_next_job_id++;
    g_jobs[g_job_count].pgid = pgid;
    g_jobs[g_job_count].cmdline = dup_cstr(cmdline ? cmdline : "");
    if (!g_jobs[g_job_count].cmdline) {
        return -1;
    }
    g_jobs[g_job_count].state = state;
    g_job_count++;
    return g_jobs[g_job_count - 1].id;
}

static void poll_jobs(void) {
    int status;
    pid_t pid;

    while ((pid = waitpid(-1, &status, WNOHANG | WUNTRACED | WCONTINUED)) > 0) {
        int i;
        for (i = 0; i < g_job_count; i++) {
            if (g_jobs[i].pgid == pid) {
                if (WIFSTOPPED(status)) {
                    g_jobs[i].state = JOB_STOPPED;
                } else if (WIFCONTINUED(status)) {
                    g_jobs[i].state = JOB_RUNNING;
                } else if (WIFEXITED(status) || WIFSIGNALED(status)) {
                    remove_job_index(i);
                }
                break;
            }
        }
    }
}

static void reset_child_signals(void) {
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTSTP, SIG_DFL);
    signal(SIGTTIN, SIG_DFL);
    signal(SIGTTOU, SIG_DFL);
}

static int resolve_builtin_path_for_name(
    const char *cmd, char *out_path, size_t out_size, int *is_user_builtin) {
    const char *builtin_dir;
    const char *home;

    if (snprintf(out_path, out_size, "builtin/%s.lua", cmd) >= (int)out_size) {
        return 0;
    }
    if (path_is_readable_file(out_path)) {
        if (is_user_builtin) {
            *is_user_builtin = 0;
        }
        return 1;
    }

    builtin_dir = getenv("LUNACMD_BUILTIN_DIR");
    if (!builtin_dir || !*builtin_dir) {
        builtin_dir = DEFAULT_BUILTIN_DIR;
    }
    if (snprintf(out_path, out_size, "%s/%s.lua", builtin_dir, cmd) < (int)out_size
        && path_is_readable_file(out_path)) {
        if (is_user_builtin) {
            *is_user_builtin = 0;
        }
        return 1;
    }

    if (is_env_enabled("LUNACMD_NO_USER_BUILTINS")) {
        return 0;
    }

    home = getenv("HOME");
    if (!home || !*home) {
        return 0;
    }

    if (snprintf(out_path, out_size, "%s/.lunacmd/builtin/%s.lua", home, cmd) >= (int)out_size) {
        return 0;
    }
    if (path_is_readable_file(out_path)) {
        if (is_user_builtin) {
            *is_user_builtin = 1;
        }
        return 1;
    }
    return 0;
}

static int lua_resolve_cmd(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    char path[PATH_MAX];
    int is_user = 0;

    lua_newtable(L);
    lua_pushstring(L, "name");
    lua_pushstring(L, cmd);
    lua_settable(L, -3);

    if (resolve_builtin_path_for_name(cmd, path, sizeof(path), &is_user)) {
        lua_pushstring(L, "kind");
        lua_pushstring(L, is_user ? "user-builtin" : "core-builtin");
        lua_settable(L, -3);

        lua_pushstring(L, "path");
        lua_pushstring(L, path);
        lua_settable(L, -3);
    } else {
        lua_pushstring(L, "kind");
        lua_pushstring(L, "lua-fallback");
        lua_settable(L, -3);
    }
    return 1;
}

static int lua_alias_fn(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    const char *value = luaL_checkstring(L, 2);

    lua_getglobal(L, "ALIASES");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
    }
    lua_pushstring(L, name);
    lua_pushstring(L, value);
    lua_settable(L, -3);
    lua_setglobal(L, "ALIASES");

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_table_is_dense_array(lua_State *L, int idx, lua_Integer *len_out) {
    lua_Integer max = 0;
    lua_Integer count = 0;
    int abs = lua_absindex(L, idx);

    if (!lua_istable(L, abs)) {
        return 0;
    }

    lua_pushnil(L);
    while (lua_next(L, abs) != 0) {
        lua_Integer k;
        if (!lua_isinteger(L, -2)) {
            lua_pop(L, 2);
            return 0;
        }
        k = lua_tointeger(L, -2);
        if (k < 1) {
            lua_pop(L, 2);
            return 0;
        }
        count++;
        if (k > max) {
            max = k;
        }
        lua_pop(L, 1);
    }

    if (max != count) {
        return 0;
    }
    if (len_out) {
        *len_out = max;
    }
    return 1;
}

static int lua_pour_fn(lua_State *L) {
    int arg_idx;
    int env_idx;
    int items_idx;
    int item_count = 0;

    if (lua_gettop(L) < 1) {
        return luaL_error(L, "pour(value) requires a value");
    }

    lua_settop(L, 1);
    arg_idx = lua_absindex(L, 1);

    lua_newtable(L);
    env_idx = lua_absindex(L, -1);

    lua_pushstring(L, "object");
    lua_setfield(L, env_idx, "__pipe_schema");
    lua_pushstring(L, "items");
    lua_setfield(L, env_idx, "__pipe_default_path");
    lua_pushstring(L, "pour");
    lua_setfield(L, env_idx, "__pipe_origin");

    lua_pushvalue(L, arg_idx);
    lua_setfield(L, env_idx, "value");

    lua_newtable(L);
    items_idx = lua_absindex(L, -1);

    if (lua_istable(L, arg_idx)) {
        lua_Integer arr_len = 0;
        if (lua_table_is_dense_array(L, arg_idx, &arr_len)) {
            lua_Integer i;
            for (i = 1; i <= arr_len; i++) {
                lua_geti(L, arg_idx, i);
                lua_seti(L, items_idx, i);
            }
        } else {
            lua_pushnil(L);
            while (lua_next(L, arg_idx) != 0) {
                lua_newtable(L);

                lua_pushvalue(L, -3);
                lua_setfield(L, -2, "key");

                lua_pushvalue(L, -2);
                lua_setfield(L, -2, "value");

                item_count++;
                lua_seti(L, items_idx, item_count);
                lua_pop(L, 1);
            }
        }
    } else {
        lua_pushvalue(L, arg_idx);
        lua_seti(L, items_idx, 1);
    }

    lua_setfield(L, env_idx, "items");

    lua_pushvalue(L, env_idx);
    lua_setglobal(L, "LUA_PIPE_OUT");
    lua_pushvalue(L, env_idx);
    return 1;
}

static int get_alias_value(lua_State *L, const char *name, char **out_value) {
    const char *value;
    *out_value = NULL;

    lua_getglobal(L, "ALIASES");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    lua_pushstring(L, name);
    lua_gettable(L, -2);
    if (!lua_isstring(L, -1)) {
        lua_pop(L, 2);
        return 0;
    }

    value = lua_tostring(L, -1);
    *out_value = dup_cstr(value);
    lua_pop(L, 2);
    return *out_value ? 1 : 0;
}

static void free_argv_list(char **argv, int argc) {
    int i;
    for (i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);
}

static int parse_words_only(const char *line, char ***argv_out, int *argc_out, char *err, size_t err_size) {
    const char *p = line;
    Token tok;
    int argc = 0;
    char **argv = NULL;

    while (1) {
        char **next;
        if (!next_token(&p, SYNTAX_LUNA, &tok, err, err_size)) {
            free_argv_list(argv, argc);
            return 0;
        }
        if (tok.type == TOKEN_EOF) {
            break;
        }
        if (tok.type != TOKEN_WORD) {
            snprintf(err, err_size, "alias value must be plain command words");
            free_token(&tok);
            free_argv_list(argv, argc);
            return 0;
        }

        next = realloc(argv, sizeof(char *) * (size_t)(argc + 1));
        if (!next) {
            free_token(&tok);
            snprintf(err, err_size, "out of memory");
            free_argv_list(argv, argc);
            return 0;
        }
        argv = next;
        argv[argc] = tok.text;
        tok.text = NULL;
        argc++;
        free_token(&tok);
    }

    *argv_out = argv;
    *argc_out = argc;
    return 1;
}

static int copy_command_argv(const CommandNode *cmd, char ***argv_out, int *argc_out, char *err, size_t err_size) {
    int i;
    char **argv = NULL;

    if (cmd->argc == 0) {
        *argv_out = NULL;
        *argc_out = 0;
        return 1;
    }

    argv = calloc((size_t)cmd->argc, sizeof(char *));
    if (!argv) {
        snprintf(err, err_size, "out of memory");
        return 0;
    }
    for (i = 0; i < cmd->argc; i++) {
        argv[i] = dup_cstr(cmd->argv[i]);
        if (!argv[i]) {
            free_argv_list(argv, i);
            snprintf(err, err_size, "out of memory");
            return 0;
        }
    }
    *argv_out = argv;
    *argc_out = cmd->argc;
    return 1;
}

static int expand_alias_argv(
    lua_State *L, const CommandNode *cmd, char ***argv_out, int *argc_out, char *err, size_t err_size) {
    int depth = 0;
    char **argv = NULL;
    int argc = 0;

    if (!copy_command_argv(cmd, &argv, &argc, err, err_size)) {
        return 0;
    }

    while (argc > 0 && depth < 16) {
        char *alias_value = NULL;
        char **prefix = NULL;
        int prefix_argc = 0;
        char **next_argv = NULL;
        int i;
        size_t next_count;

        if (!get_alias_value(L, argv[0], &alias_value)) {
            break;
        }

        if (!parse_words_only(alias_value, &prefix, &prefix_argc, err, err_size)) {
            free(alias_value);
            free_argv_list(argv, argc);
            return 0;
        }
        free(alias_value);

        if (prefix_argc == 0) {
            free_argv_list(prefix, prefix_argc);
            free_argv_list(argv, argc);
            snprintf(err, err_size, "alias expansion cannot be empty");
            return 0;
        }

        next_count = (size_t)prefix_argc + (size_t)(argc > 0 ? argc - 1 : 0);
        next_argv = calloc(next_count, sizeof(char *));
        if (!next_argv) {
            free_argv_list(prefix, prefix_argc);
            free_argv_list(argv, argc);
            snprintf(err, err_size, "out of memory");
            return 0;
        }

        for (i = 0; i < prefix_argc; i++) {
            next_argv[i] = prefix[i];
            prefix[i] = NULL;
        }
        for (i = 1; i < argc; i++) {
            next_argv[prefix_argc + i - 1] = argv[i];
            argv[i] = NULL;
        }

        free_argv_list(prefix, prefix_argc);
        free_argv_list(argv, argc);
        argv = next_argv;
        argc = (int)next_count;
        depth++;
    }

    if (depth >= 16) {
        free_argv_list(argv, argc);
        snprintf(err, err_size, "alias expansion too deep");
        return 0;
    }

    *argv_out = argv;
    *argc_out = argc;
    return 1;
}

static int set_global_from_global(lua_State *L, const char *src_name, const char *dst_name) {
    int is_nil;
    lua_getglobal(L, src_name);
    is_nil = lua_isnil(L, -1);
    lua_setglobal(L, dst_name);
    return !is_nil;
}

static void update_prompt_context(lua_State *L, int last_status, const char *mode) {
    time_t now = time(NULL);

    if (!set_global_from_global(L, "G_CWD", "PWD")) {
        lua_pushstring(L, ".");
        lua_setglobal(L, "PWD");
    }

    lua_pushinteger(L, last_status);
    lua_setglobal(L, "LAST_STATUS");

    lua_pushstring(L, mode ? mode : "lua");
    lua_setglobal(L, "MODE");

    lua_pushinteger(L, (lua_Integer)now);
    lua_setglobal(L, "TIME");
}

static char *dup_cstr(const char *s) {
    size_t n;
    char *out;
    if (!s) {
        s = "";
    }
    n = strlen(s);
    out = malloc(n + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, s, n + 1);
    return out;
}

static char *get_prompt_string(
    lua_State *L, const char *global_name, const char *fallback, int *warned_once) {
    char *result = NULL;
    int type;

    lua_getglobal(L, global_name);
    type = lua_type(L, -1);

    if (type == LUA_TNIL) {
        lua_pop(L, 1);
        return dup_cstr(fallback);
    }

    if (type == LUA_TFUNCTION) {
        if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
            if (warned_once && !*warned_once) {
                fprintf(stderr, "Prompt error (%s): %s\n", global_name, lua_tostring(L, -1));
                *warned_once = 1;
            }
            lua_pop(L, 1);
            return dup_cstr(fallback);
        }
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            return dup_cstr(fallback);
        }
        if (lua_isstring(L, -1)) {
            const char *s = lua_tostring(L, -1);
            result = dup_cstr(s);
            lua_pop(L, 1);
            return result ? result : dup_cstr(fallback);
        }
        luaL_tolstring(L, -1, NULL);
        result = dup_cstr(lua_tostring(L, -1));
        lua_pop(L, 2);
        return result ? result : dup_cstr(fallback);
    }

    if (lua_isstring(L, -1)) {
        const char *s = lua_tostring(L, -1);
        result = dup_cstr(s);
        lua_pop(L, 1);
        return result ? result : dup_cstr(fallback);
    }

    luaL_tolstring(L, -1, NULL);
    result = dup_cstr(lua_tostring(L, -1));
    lua_pop(L, 2);
    return result ? result : dup_cstr(fallback);
}

static void maybe_load_user_rc(lua_State *L) {
    const char *skip = getenv("LUNACMD_NO_RC");
    const char *home = getenv("HOME");
    char path[PATH_MAX];

    if (skip && *skip) {
        return;
    }
    if (!home || !*home) {
        return;
    }
    if (snprintf(path, sizeof(path), "%s/.lunacmd.lua", home) >= (int)sizeof(path)) {
        return;
    }
    if (access(path, R_OK) != 0) {
        return;
    }

    if (luaL_dofile(L, path) != LUA_OK) {
        fprintf(stderr, "Failed to load %s: %s\n", path, lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

static int lua_listdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    DIR *dir = opendir(path);
    struct dirent *entry;
    int idx = 1;

    if (!dir) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_newtable(L);
    while ((entry = readdir(dir)) != NULL) {
        lua_pushinteger(L, idx++);
        lua_pushstring(L, entry->d_name);
        lua_settable(L, -3);
    }

    closedir(dir);
    return 1;
}

static int lua_isdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    struct stat st;

    if (stat(path, &st) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_pushboolean(L, S_ISDIR(st.st_mode));
    return 1;
}

static int lua_mkdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);

    if (mkdir(path, 0777) == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }

    if (errno == EEXIST) {
        struct stat st;
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
            lua_pushboolean(L, 1);
            return 1;
        }
    }

    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
}

static int lua_sleep(lua_State *L) {
    double seconds = luaL_checknumber(L, 1);
    struct timespec req;
    struct timespec rem;

    if (seconds < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "negative duration");
        return 2;
    }

    req.tv_sec = (time_t)seconds;
    req.tv_nsec = (long)((seconds - (double)req.tv_sec) * 1000000000.0);
    if (req.tv_nsec < 0) {
        req.tv_nsec = 0;
    }

    while (nanosleep(&req, &rem) != 0) {
        if (errno == EINTR) {
            req = rem;
            continue;
        }
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_getch(lua_State *L) {
    int fd = open("/dev/tty", O_RDONLY);
    struct termios oldt;
    struct termios raw;
    unsigned char ch;
    ssize_t nread;

    if (fd < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    if (tcgetattr(fd, &oldt) != 0) {
        close(fd);
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    raw = oldt;
    raw.c_lflag &= (tcflag_t) ~(ICANON | ECHO);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(fd, TCSANOW, &raw) != 0) {
        close(fd);
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    nread = read(fd, &ch, 1);
    tcsetattr(fd, TCSANOW, &oldt);
    close(fd);

    if (nread != 1) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to read character");
        return 2;
    }

    lua_pushlstring(L, (const char *)&ch, 1);
    return 1;
}

static void push_stat_table(lua_State *L, const struct stat *st) {
    const char *kind = "unknown";

    if (S_ISREG(st->st_mode)) {
        kind = "file";
    } else if (S_ISDIR(st->st_mode)) {
        kind = "dir";
    } else if (S_ISLNK(st->st_mode)) {
        kind = "symlink";
    } else if (S_ISCHR(st->st_mode)) {
        kind = "char";
    } else if (S_ISBLK(st->st_mode)) {
        kind = "block";
    } else if (S_ISFIFO(st->st_mode)) {
        kind = "fifo";
    } else if (S_ISSOCK(st->st_mode)) {
        kind = "socket";
    }

    lua_newtable(L);

    lua_pushstring(L, "mode");
    lua_pushinteger(L, (lua_Integer)st->st_mode);
    lua_settable(L, -3);

    lua_pushstring(L, "nlink");
    lua_pushinteger(L, (lua_Integer)st->st_nlink);
    lua_settable(L, -3);

    lua_pushstring(L, "uid");
    lua_pushinteger(L, (lua_Integer)st->st_uid);
    lua_settable(L, -3);

    lua_pushstring(L, "gid");
    lua_pushinteger(L, (lua_Integer)st->st_gid);
    lua_settable(L, -3);

    lua_pushstring(L, "size");
    lua_pushinteger(L, (lua_Integer)st->st_size);
    lua_settable(L, -3);

    lua_pushstring(L, "atime");
    lua_pushinteger(L, (lua_Integer)st->st_atime);
    lua_settable(L, -3);

    lua_pushstring(L, "mtime");
    lua_pushinteger(L, (lua_Integer)st->st_mtime);
    lua_settable(L, -3);

    lua_pushstring(L, "ctime");
    lua_pushinteger(L, (lua_Integer)st->st_ctime);
    lua_settable(L, -3);

    lua_pushstring(L, "ino");
    lua_pushinteger(L, (lua_Integer)st->st_ino);
    lua_settable(L, -3);

    lua_pushstring(L, "blocks");
    lua_pushinteger(L, (lua_Integer)st->st_blocks);
    lua_settable(L, -3);

    lua_pushstring(L, "blksize");
    lua_pushinteger(L, (lua_Integer)st->st_blksize);
    lua_settable(L, -3);

    lua_pushstring(L, "kind");
    lua_pushstring(L, kind);
    lua_settable(L, -3);

    lua_pushstring(L, "executable");
    lua_pushboolean(L, (st->st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0);
    lua_settable(L, -3);
}

static int lua_stat(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int follow = lua_toboolean(L, 2);
    struct stat st;
    int rc;

    if (follow) {
        rc = stat(path, &st);
    } else {
        rc = lstat(path, &st);
    }
    if (rc != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    push_stat_table(L, &st);
    return 1;
}

static int lua_readlink(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    char buf[PATH_MAX];
    ssize_t n = readlink(path, buf, sizeof(buf) - 1);

    if (n < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    buf[n] = '\0';
    lua_pushstring(L, buf);
    return 1;
}

static int lua_uid_name(lua_State *L) {
    uid_t uid = (uid_t)luaL_checkinteger(L, 1);
    struct passwd *pw = getpwuid(uid);
    if (!pw || !pw->pw_name) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, pw->pw_name);
    return 1;
}

static int lua_gid_name(lua_State *L) {
    gid_t gid = (gid_t)luaL_checkinteger(L, 1);
    struct group *gr = getgrgid(gid);
    if (!gr || !gr->gr_name) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, gr->gr_name);
    return 1;
}

static int lua_isatty(lua_State *L) {
    int fd = (int)luaL_optinteger(L, 1, STDOUT_FILENO);
    lua_pushboolean(L, isatty(fd) ? 1 : 0);
    return 1;
}

static int copy_file_contents(const char *src, const char *dst) {
    int in_fd = -1;
    int out_fd = -1;
    char buf[8192];

    in_fd = open(src, O_RDONLY);
    if (in_fd < 0) {
        return 0;
    }
    out_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        close(in_fd);
        return 0;
    }

    while (1) {
        ssize_t nread = read(in_fd, buf, sizeof(buf));
        if (nread < 0) {
            close(in_fd);
            close(out_fd);
            return 0;
        }
        if (nread == 0) {
            break;
        }
        {
            ssize_t written = 0;
            while (written < nread) {
                ssize_t nw = write(out_fd, buf + written, (size_t)(nread - written));
                if (nw <= 0) {
                    close(in_fd);
                    close(out_fd);
                    return 0;
                }
                written += nw;
            }
        }
    }

    close(in_fd);
    close(out_fd);
    return 1;
}

static int lua_lunabuffer_status(lua_State *L) {
    size_t mem_size = 0;
    size_t file_size = 0;

    if (!init_luna_buffers()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to initialize buffers");
        return 2;
    }

    file_size_bytes(g_luna_buffer.mem_path, &mem_size);
    file_size_bytes(g_luna_buffer.file_path, &file_size);

    lua_newtable(L);

    lua_pushstring(L, "mem");
    lua_newtable(L);
    lua_pushstring(L, "path");
    lua_pushstring(L, g_luna_buffer.mem_path);
    lua_settable(L, -3);
    lua_pushstring(L, "size");
    lua_pushinteger(L, (lua_Integer)mem_size);
    lua_settable(L, -3);
    lua_pushstring(L, "max");
    lua_pushinteger(L, (lua_Integer)g_luna_buffer.mem_max);
    lua_settable(L, -3);
    lua_settable(L, -3);

    lua_pushstring(L, "file");
    lua_newtable(L);
    lua_pushstring(L, "path");
    lua_pushstring(L, g_luna_buffer.file_path);
    lua_settable(L, -3);
    lua_pushstring(L, "size");
    lua_pushinteger(L, (lua_Integer)file_size);
    lua_settable(L, -3);
    lua_settable(L, -3);

    return 1;
}

static int lua_lunabuffer_set_size(lua_State *L) {
    size_t n = (size_t)luaL_checkinteger(L, 1);
    if (!init_luna_buffers()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to initialize buffers");
        return 2;
    }
    if (n == 0) {
        lua_pushnil(L);
        lua_pushstring(L, "size must be greater than zero");
        return 2;
    }
    g_luna_buffer.mem_max = n;
    if (!clamp_memory_buffer()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to clamp memory buffer");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_lunabuffer_clear(lua_State *L) {
    const char *kind = luaL_optstring(L, 1, "all");
    int do_mem = 0;
    int do_file = 0;
    int fd;

    if (!init_luna_buffers()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to initialize buffers");
        return 2;
    }

    if (strcmp(kind, "mem") == 0) {
        do_mem = 1;
    } else if (strcmp(kind, "file") == 0) {
        do_file = 1;
    } else if (strcmp(kind, "all") == 0) {
        do_mem = 1;
        do_file = 1;
    } else {
        lua_pushnil(L);
        lua_pushstring(L, "kind must be mem, file, or all");
        return 2;
    }

    if (do_mem) {
        fd = open(g_luna_buffer.mem_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            return 2;
        }
        close(fd);
    }
    if (do_file) {
        fd = open(g_luna_buffer.file_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            return 2;
        }
        close(fd);
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_lunabuffer_save(lua_State *L) {
    const char *kind = luaL_checkstring(L, 1);
    const char *dest = luaL_checkstring(L, 2);
    const char *src = NULL;
    int is_mem = 0;

    if (!init_luna_buffers()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to initialize buffers");
        return 2;
    }

    if (strcmp(kind, "mem") == 0) {
        src = g_luna_buffer.mem_path;
        is_mem = 1;
    } else if (strcmp(kind, "file") == 0) {
        src = g_luna_buffer.file_path;
    } else {
        lua_pushnil(L);
        lua_pushstring(L, "kind must be mem or file");
        return 2;
    }

    if (!copy_file_contents(src, dest)) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    if (is_mem) {
        clamp_memory_buffer();
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_history_list(lua_State *L) {
    HIST_ENTRY **entries;
    int i = 0;

    lua_newtable(L);
    entries = history_list();
    if (!entries) {
        return 1;
    }

    while (entries[i]) {
        lua_newtable(L);
        lua_pushstring(L, "id");
        lua_pushinteger(L, (lua_Integer)(history_base + i));
        lua_settable(L, -3);
        lua_pushstring(L, "line");
        lua_pushstring(L, entries[i]->line ? entries[i]->line : "");
        lua_settable(L, -3);
        lua_pushinteger(L, i + 1);
        lua_pushvalue(L, -2);
        lua_settable(L, -4);
        lua_pop(L, 1);
        i++;
    }
    return 1;
}

static int lua_history_clear(lua_State *L) {
    clear_history();
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_history_read(lua_State *L) {
    int rc;
    if (!init_history_path()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to initialize history path");
        return 2;
    }
    rc = read_history(g_history_path);
    if (rc != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_history_write(lua_State *L) {
    int rc;
    if (!init_history_path()) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to initialize history path");
        return 2;
    }
    rc = write_history(g_history_path);
    if (rc != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_history_path(lua_State *L) {
    if (!init_history_path()) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, g_history_path);
    return 1;
}

static void sync_preview_mode_from_lua(lua_State *L) {
    lua_getglobal(L, "PREVIEW_MODE");
    if (lua_isboolean(L, -1)) {
        g_preview_mode = lua_toboolean(L, -1) ? 1 : 0;
    }
    lua_pop(L, 1);
}

static int lua_preview_get(lua_State *L) {
    sync_preview_mode_from_lua(L);
    lua_pushboolean(L, g_preview_mode);
    return 1;
}

static int lua_preview_set(lua_State *L) {
    int enabled = lua_toboolean(L, 1) ? 1 : 0;
    g_preview_mode = enabled;
    lua_pushboolean(L, g_preview_mode);
    lua_setglobal(L, "PREVIEW_MODE");
    lua_pushboolean(L, g_preview_mode);
    return 1;
}

static int lua_jobs_list(lua_State *L) {
    int i;
    poll_jobs();
    lua_newtable(L);
    for (i = 0; i < g_job_count; i++) {
        lua_newtable(L);
        lua_pushstring(L, "id");
        lua_pushinteger(L, g_jobs[i].id);
        lua_settable(L, -3);
        lua_pushstring(L, "pgid");
        lua_pushinteger(L, (lua_Integer)g_jobs[i].pgid);
        lua_settable(L, -3);
        lua_pushstring(L, "state");
        lua_pushstring(L, g_jobs[i].state == JOB_RUNNING ? "running" : "stopped");
        lua_settable(L, -3);
        lua_pushstring(L, "cmd");
        lua_pushstring(L, g_jobs[i].cmdline ? g_jobs[i].cmdline : "");
        lua_settable(L, -3);
        lua_pushinteger(L, i + 1);
        lua_pushvalue(L, -2);
        lua_settable(L, -4);
        lua_pop(L, 1);
    }
    return 1;
}

static int wait_foreground_job(pid_t pgid, int *stopped_out, int *status_out) {
    int status = 0;
    pid_t r;
    int has_tty = isatty(STDIN_FILENO);
    *stopped_out = 0;
    *status_out = 0;

    if (has_tty) {
        tcsetpgrp(STDIN_FILENO, pgid);
    }
    r = waitpid(pgid, &status, WUNTRACED);
    if (has_tty) {
        tcsetpgrp(STDIN_FILENO, g_shell_pgid);
    }

    if (r < 0) {
        return 0;
    }
    if (WIFSTOPPED(status)) {
        *stopped_out = 1;
        return 1;
    }
    if (WIFEXITED(status)) {
        *status_out = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        *status_out = 128 + WTERMSIG(status);
    }
    return 1;
}

static int lua_job_fg(lua_State *L) {
    int id = (int)luaL_checkinteger(L, 1);
    Job *job = find_job_by_id(id);
    int stopped = 0;
    int status = 0;
    int idx;

    poll_jobs();
    if (!job) {
        lua_pushnil(L);
        lua_pushstring(L, "job not found");
        return 2;
    }

    if (kill(-job->pgid, SIGCONT) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    job->state = JOB_RUNNING;

    if (!wait_foreground_job(job->pgid, &stopped, &status)) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    if (stopped) {
        job->state = JOB_STOPPED;
    } else {
        for (idx = 0; idx < g_job_count; idx++) {
            if (g_jobs[idx].id == id) {
                remove_job_index(idx);
                break;
            }
        }
    }

    lua_pushboolean(L, 1);
    lua_pushinteger(L, status);
    return 2;
}

static int lua_job_bg(lua_State *L) {
    int id = (int)luaL_checkinteger(L, 1);
    Job *job;
    poll_jobs();
    job = find_job_by_id(id);
    if (!job) {
        lua_pushnil(L);
        lua_pushstring(L, "job not found");
        return 2;
    }
    if (kill(-job->pgid, SIGCONT) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    job->state = JOB_RUNNING;
    lua_pushboolean(L, 1);
    return 1;
}

static void free_token(Token *token) {
    if (token->text) {
        free(token->text);
        token->text = NULL;
    }
}

static void free_command_node(CommandNode *cmd) {
    int i;
    if (!cmd) {
        return;
    }
    for (i = 0; i < cmd->argc; i++) {
        free(cmd->argv[i]);
    }
    free(cmd->argv);
    cmd->argv = NULL;
    cmd->argc = 0;

    for (i = 0; i < cmd->redir_count; i++) {
        free(cmd->redirs[i].target);
    }
    free(cmd->redirs);
    cmd->redirs = NULL;
    cmd->redir_count = 0;
}

static void free_command_ast(CommandAst *ast) {
    int i;
    if (!ast) {
        return;
    }
    for (i = 0; i < ast->pipeline.command_count; i++) {
        free_command_node(&ast->pipeline.commands[i]);
    }
    free(ast->pipeline.commands);
    ast->pipeline.commands = NULL;
    ast->pipeline.command_count = 0;
    free(ast->pipeline.pipes);
    ast->pipeline.pipes = NULL;
    ast->pipeline.pipe_count = 0;
}

static int append_char(char **buffer, size_t *len, size_t *capacity, char c) {
    char *next;
    if (*len + 1 >= *capacity) {
        size_t new_capacity = (*capacity == 0) ? 16 : (*capacity * 2);
        next = realloc(*buffer, new_capacity);
        if (!next) {
            return 0;
        }
        *buffer = next;
        *capacity = new_capacity;
    }
    (*buffer)[*len] = c;
    (*len)++;
    return 1;
}

static int append_bytes(char **buffer, size_t *len, size_t *capacity, const char *src, size_t src_len) {
    size_t i;
    for (i = 0; i < src_len; i++) {
        if (!append_char(buffer, len, capacity, src[i])) {
            return 0;
        }
    }
    return 1;
}

static int append_argument(CommandNode *cmd, char *arg) {
    char **next = realloc(cmd->argv, sizeof(char *) * (size_t)(cmd->argc + 1));
    if (!next) {
        return 0;
    }
    cmd->argv = next;
    cmd->argv[cmd->argc] = arg;
    cmd->argc++;
    return 1;
}

static int append_redirection(CommandNode *cmd, RedirType type, char *target) {
    Redirection *next = realloc(cmd->redirs, sizeof(Redirection) * (size_t)(cmd->redir_count + 1));
    if (!next) {
        return 0;
    }
    cmd->redirs = next;
    cmd->redirs[cmd->redir_count].type = type;
    cmd->redirs[cmd->redir_count].target = target;
    cmd->redir_count++;
    return 1;
}

static int append_pipeline_command(PipelineNode *pipeline, CommandNode *cmd) {
    CommandNode *next = realloc(
        pipeline->commands, sizeof(CommandNode) * (size_t)(pipeline->command_count + 1));
    if (!next) {
        return 0;
    }
    pipeline->commands = next;
    pipeline->commands[pipeline->command_count] = *cmd;
    pipeline->command_count++;

    cmd->argc = 0;
    cmd->argv = NULL;
    cmd->redir_count = 0;
    cmd->redirs = NULL;
    return 1;
}

static int append_pipeline_pipe(PipelineNode *pipeline, PipeType type) {
    PipeType *next;
    next = realloc(pipeline->pipes, sizeof(PipeType) * (size_t)(pipeline->pipe_count + 1));
    if (!next) {
        return 0;
    }
    pipeline->pipes = next;
    pipeline->pipes[pipeline->pipe_count] = type;
    pipeline->pipe_count++;
    return 1;
}

static int match_operator(
    const char *p, ParseSyntaxMode mode, TokenType *type, size_t *op_len) {
    if (mode == SYNTAX_LEGACY) {
        if (starts_with(p, "2>&1")) {
            *type = TOKEN_REDIR_ERR_TO_OUT;
            *op_len = 4;
            return 1;
        }
        if (starts_with(p, "2>>")) {
            *type = TOKEN_REDIR_ERR_OUT_APPEND;
            *op_len = 3;
            return 1;
        }
        if (starts_with(p, "2>")) {
            *type = TOKEN_REDIR_ERR_OUT;
            *op_len = 2;
            return 1;
        }
        if (starts_with(p, ">>")) {
            *type = TOKEN_REDIR_OUT_APPEND;
            *op_len = 2;
            return 1;
        }
        if (*p == '|') {
            *type = TOKEN_PIPE;
            *op_len = 1;
            return 1;
        }
        if (*p == '<') {
            *type = TOKEN_REDIR_IN;
            *op_len = 1;
            return 1;
        }
        if (*p == '>') {
            *type = TOKEN_REDIR_OUT;
            *op_len = 1;
            return 1;
        }
    } else {
        if (starts_with(p, "2:>&1")) {
            *type = TOKEN_REDIR_ERR_TO_OUT;
            *op_len = 5;
            return 1;
        }
        if (starts_with(p, "2:>>")) {
            *type = TOKEN_REDIR_ERR_OUT_APPEND;
            *op_len = 4;
            return 1;
        }
        if (starts_with(p, "2:>")) {
            *type = TOKEN_REDIR_ERR_OUT;
            *op_len = 3;
            return 1;
        }
        if (starts_with(p, ":>>")) {
            *type = TOKEN_REDIR_OUT_APPEND;
            *op_len = 3;
            return 1;
        }
        if (starts_with(p, ":||")) {
            *type = TOKEN_LUA_PIPE;
            *op_len = 3;
            return 1;
        }
        if (starts_with(p, ":|")) {
            *type = TOKEN_PIPE;
            *op_len = 2;
            return 1;
        }
        if (starts_with(p, ":<")) {
            *type = TOKEN_REDIR_IN;
            *op_len = 2;
            return 1;
        }
        if (starts_with(p, ":>")) {
            *type = TOKEN_REDIR_OUT;
            *op_len = 2;
            return 1;
        }
    }
    return 0;
}

static int is_legacy_operator_word(const char *word) {
    return strcmp(word, "|") == 0 || strcmp(word, "<") == 0 || strcmp(word, ">") == 0 ||
           strcmp(word, ">>") == 0 || strcmp(word, "2>") == 0 || strcmp(word, "2>>") == 0 ||
           strcmp(word, "2>&1") == 0;
}

static int next_token(const char **input, ParseSyntaxMode mode, Token *out, char *err, size_t err_size) {
    const char *p = *input;
    char *word = NULL;
    size_t word_len = 0;
    size_t word_cap = 0;
    int in_single = 0;
    int in_double = 0;
    TokenType op_type;
    size_t op_len = 0;

    out->type = TOKEN_EOF;
    out->text = NULL;

    while (*p && isspace((unsigned char)*p)) {
        p++;
    }

    if (*p == '\0') {
        *input = p;
        return 1;
    }

    if (match_operator(p, mode, &op_type, &op_len)) {
        out->type = op_type;
        *input = p + op_len;
        return 1;
    }

    while (*p) {
        if (!in_single && !in_double) {
            if (isspace((unsigned char)*p)) {
                break;
            }
            if (match_operator(p, mode, &op_type, &op_len)) {
                break;
            }
            if (*p == '`') {
                if (!append_char(&word, &word_len, &word_cap, *p)) {
                    snprintf(err, err_size, "out of memory");
                    free(word);
                    return 0;
                }
                p++;
                while (*p && *p != '`') {
                    if (!append_char(&word, &word_len, &word_cap, *p)) {
                        snprintf(err, err_size, "out of memory");
                        free(word);
                        return 0;
                    }
                    p++;
                }
                if (*p != '`') {
                    snprintf(err, err_size, "unterminated command substitution");
                    free(word);
                    return 0;
                }
                if (!append_char(&word, &word_len, &word_cap, *p)) {
                    snprintf(err, err_size, "out of memory");
                    free(word);
                    return 0;
                }
                p++;
                continue;
            }
        }

        if (!in_single && *p == '"') {
            in_double = !in_double;
            p++;
            continue;
        }
        if (!in_double && *p == '\'') {
            in_single = !in_single;
            p++;
            continue;
        }
        if (!in_single && *p == '\\') {
            p++;
            if (*p == '\0') {
                if (!append_char(&word, &word_len, &word_cap, '\\')) {
                    snprintf(err, err_size, "out of memory");
                    free(word);
                    return 0;
                }
                break;
            }
        }
        if (!append_char(&word, &word_len, &word_cap, *p)) {
            snprintf(err, err_size, "out of memory");
            free(word);
            return 0;
        }
        p++;
    }

    if (in_single || in_double) {
        snprintf(err, err_size, "unterminated quote");
        free(word);
        return 0;
    }

    if (!append_char(&word, &word_len, &word_cap, '\0')) {
        snprintf(err, err_size, "out of memory");
        free(word);
        return 0;
    }

    out->type = TOKEN_WORD;
    out->text = word;
    *input = p;
    return 1;
}

static int parse_to_ast(
    const char *line, ParseSyntaxMode mode, CommandAst *ast, char *err, size_t err_size) {
    const char *p = line;
    Token tok;
    CommandNode current = {0};

    memset(ast, 0, sizeof(*ast));

    if (!next_token(&p, mode, &tok, err, err_size)) {
        return 0;
    }
    if (tok.type == TOKEN_EOF) {
        return 1;
    }

    while (1) {
        int saw_command_word = 0;

        while (tok.type != TOKEN_EOF && tok.type != TOKEN_PIPE && tok.type != TOKEN_LUA_PIPE) {
            if (tok.type == TOKEN_WORD) {
                if (mode == SYNTAX_LUNA && is_legacy_operator_word(tok.text)) {
                    snprintf(err,
                             err_size,
                             "legacy operator '%s' requires ':!' prefix (or use lunacmd operators like :>, :<, :|, :||)",
                             tok.text);
                    free_token(&tok);
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }
                if (!append_argument(&current, tok.text)) {
                    free(tok.text);
                    snprintf(err, err_size, "out of memory");
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }
                tok.text = NULL;
                saw_command_word = 1;
            } else {
                RedirType rtype;
                Token target;
                char *target_text = NULL;

                if (tok.type == TOKEN_REDIR_IN) {
                    rtype = REDIR_IN;
                } else if (tok.type == TOKEN_REDIR_OUT) {
                    rtype = REDIR_OUT;
                } else if (tok.type == TOKEN_REDIR_OUT_APPEND) {
                    rtype = REDIR_OUT_APPEND;
                } else if (tok.type == TOKEN_REDIR_ERR_OUT) {
                    rtype = REDIR_ERR_OUT;
                } else if (tok.type == TOKEN_REDIR_ERR_OUT_APPEND) {
                    rtype = REDIR_ERR_OUT_APPEND;
                } else if (tok.type == TOKEN_REDIR_ERR_TO_OUT) {
                    rtype = REDIR_ERR_TO_OUT;
                    if (!append_redirection(&current, rtype, NULL)) {
                        snprintf(err, err_size, "out of memory");
                        free_command_node(&current);
                        free_command_ast(ast);
                        return 0;
                    }
                    free_token(&tok);
                    if (!next_token(&p, mode, &tok, err, err_size)) {
                        free_command_node(&current);
                        free_command_ast(ast);
                        return 0;
                    }
                    continue;
                } else {
                    snprintf(err, err_size, "unexpected token");
                    free_token(&tok);
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }

                free_token(&tok);
                if (!next_token(&p, mode, &target, err, err_size)) {
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }
                if (target.type != TOKEN_WORD) {
                    free_token(&target);
                    snprintf(err, err_size, "redirection requires a file target");
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }

                target_text = target.text;
                target.text = NULL;
                free_token(&target);

                if (!append_redirection(&current, rtype, target_text)) {
                    free(target_text);
                    snprintf(err, err_size, "out of memory");
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }

                if (!next_token(&p, mode, &tok, err, err_size)) {
                    free_command_node(&current);
                    free_command_ast(ast);
                    return 0;
                }
                continue;
            }

            free_token(&tok);
            if (!next_token(&p, mode, &tok, err, err_size)) {
                free_command_node(&current);
                free_command_ast(ast);
                return 0;
            }
        }

        if (!saw_command_word) {
            snprintf(err, err_size, "missing command name");
            free_token(&tok);
            free_command_node(&current);
            free_command_ast(ast);
            return 0;
        }

        if (!append_pipeline_command(&ast->pipeline, &current)) {
            snprintf(err, err_size, "out of memory");
            free_token(&tok);
            free_command_node(&current);
            free_command_ast(ast);
            return 0;
        }

        if (tok.type == TOKEN_EOF) {
            break;
        }

        if (!append_pipeline_pipe(
                &ast->pipeline, tok.type == TOKEN_LUA_PIPE ? PIPE_LUA : PIPE_TEXT)) {
            snprintf(err, err_size, "out of memory");
            free_token(&tok);
            free_command_ast(ast);
            return 0;
        }

        free_token(&tok);
        if (!next_token(&p, mode, &tok, err, err_size)) {
            free_command_ast(ast);
            return 0;
        }
        if (tok.type == TOKEN_EOF) {
            snprintf(err, err_size, "pipe requires a command on the right side");
            free_command_ast(ast);
            return 0;
        }
    }

    free_token(&tok);
    return 1;
}

static void set_lua_command_globals(lua_State *L, const CommandNode *cmd) {
    int i;
    lua_pushstring(L, cmd->argv[0]);
    lua_setglobal(L, "CMD");

    lua_newtable(L);
    for (i = 1; i < cmd->argc; i++) {
        lua_pushinteger(L, i);
        lua_pushstring(L, cmd->argv[i]);
        lua_settable(L, -3);
    }
    lua_setglobal(L, "ARGS");

    lua_pushinteger(L, cmd->argc - 1);
    lua_setglobal(L, "ARGC");
}

static const char *redirection_name(RedirType type) {
    if (type == REDIR_IN) {
        return "stdin";
    }
    if (type == REDIR_OUT) {
        return "stdout";
    }
    if (type == REDIR_OUT_APPEND) {
        return "stdout-append";
    }
    if (type == REDIR_ERR_OUT) {
        return "stderr";
    }
    if (type == REDIR_ERR_OUT_APPEND) {
        return "stderr-append";
    }
    if (type == REDIR_ERR_TO_OUT) {
        return "stderr->stdout";
    }
    return "unknown";
}

static int command_is_mutating_builtin(const char *name) {
    const char *mutating[] = {"cp", "mv", "rm", "mkdir", "rmdir", "lunabuffer", "setprompt", "alias"};
    int i;
    for (i = 0; i < (int)(sizeof(mutating) / sizeof(mutating[0])); i++) {
        if (strcmp(name, mutating[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static int ast_has_output_redirection(const CommandAst *ast) {
    int i, j;
    for (i = 0; i < ast->pipeline.command_count; i++) {
        const CommandNode *cmd = &ast->pipeline.commands[i];
        for (j = 0; j < cmd->redir_count; j++) {
            RedirType t = cmd->redirs[j].type;
            if (t == REDIR_OUT || t == REDIR_OUT_APPEND || t == REDIR_ERR_OUT || t == REDIR_ERR_OUT_APPEND
                || t == REDIR_ERR_TO_OUT) {
                return 1;
            }
        }
    }
    return 0;
}

static void print_preview_plan(
    lua_State *L, const CommandAst *ast, const char *line, int background, const char *execution_state) {
    int i, j;
    int has_external = 0;
    int mutating = ast_has_output_redirection(ast);
    const char *risk = "safe";

    printf("[preview] line: %s\n", line ? line : "");
    lua_getglobal(L, "G_CWD");
    if (lua_isstring(L, -1)) {
        printf("[preview] cwd: %s\n", lua_tostring(L, -1));
    }
    lua_pop(L, 1);

    for (i = 0; i < ast->pipeline.command_count; i++) {
        const CommandNode *cmd = &ast->pipeline.commands[i];
        char **argv = NULL;
        int argc = 0;
        int is_user_builtin = 0;
        int has_builtin = 0;
        char builtin_path[PATH_MAX];
        char alias_err[MAX_PARSE_ERR];
        char glob_err[MAX_PARSE_ERR];
        const char *kind = "lua-fallback";

        if (!copy_command_argv(cmd, &argv, &argc, alias_err, sizeof(alias_err))) {
            fprintf(stderr, "[preview] warning: %s\n", alias_err);
            continue;
        }

        if (!expand_alias_argv(L, cmd, &argv, &argc, alias_err, sizeof(alias_err))) {
            fprintf(stderr, "[preview] warning: alias expansion failed: %s\n", alias_err);
            free_argv_list(argv, argc);
            continue;
        }

        has_builtin = argc > 0
            ? resolve_builtin_path_for_name(argv[0], builtin_path, sizeof(builtin_path), &is_user_builtin)
            : 0;

        if (has_builtin) {
            kind = is_user_builtin ? "user-builtin" : "core-builtin";
            if (!expand_builtin_globs(L, &argv, &argc, glob_err, sizeof(glob_err))) {
                fprintf(stderr, "[preview] warning: glob expansion failed: %s\n", glob_err);
            }
        } else if (argc > 0 && strcmp(argv[0], "exec") == 0) {
            kind = "external";
            has_external = 1;
        } else if (argc > 0) {
            kind = "lua-fallback";
        }

        if (argc > 0 && command_is_mutating_builtin(argv[0])) {
            mutating = 1;
        }

        printf("[preview] cmd[%d] kind=%s", i + 1, kind);
        if (has_builtin) {
            printf(" path=%s", builtin_path);
        }
        printf("\n");

        for (j = 0; j < argc; j++) {
            printf("[preview]   argv[%d]=%s\n", j, argv[j] ? argv[j] : "");
        }
        for (j = 0; j < cmd->redir_count; j++) {
            Redirection *r = &cmd->redirs[j];
            printf("[preview]   redir %s -> %s\n", redirection_name(r->type), r->target ? r->target : "");
        }
        free_argv_list(argv, argc);
    }

    if (ast->pipeline.command_count > 1) {
        int has_lua = 0;
        for (i = 0; i < ast->pipeline.pipe_count; i++) {
            if (ast->pipeline.pipes[i] == PIPE_LUA) {
                has_lua = 1;
                break;
            }
        }
        printf("[preview] pipeline: %d stages (%s)\n", ast->pipeline.command_count, has_lua ? "lua-table" : "text");
    }
    if (background) {
        printf("[preview] background: yes\n");
    }

    if (has_external) {
        risk = "external";
    } else if (mutating) {
        risk = "mutating";
    }
    printf("[preview] risk: %s\n", risk);
    printf("[preview] execution: %s\n", execution_state ? execution_state : "skipped");
}

static int confirm_preview_exec(void) {
    char c;
    int seen = 0;
    int yes = 0;
    ssize_t n;
    printf("[preview] execute this command? [y/N] ");
    fflush(stdout);
    while ((n = read(STDIN_FILENO, &c, 1)) == 1) {
        if (!seen) {
            if (c == '\n') {
                break;
            }
            if (isspace((unsigned char)c)) {
                continue;
            }
            seen = 1;
            yes = (c == 'y' || c == 'Y') ? 1 : 0;
        }
        if (c == '\n') {
            break;
        }
    }
    if (!seen) {
        return 0;
    }
    return yes;
}

/* Read a string, and return a pointer to it.
   Returns NULL on EOF. */
char *rl_gets(const char *prompt, int store_history) {
    /* If the buffer has already been allocated,
       return the memory to the free pool. */
    if (line_read) {
        free(line_read);
        line_read = (char *)NULL;
    }

    /* Get a line from the user. */
    line_read = readline(prompt);

    /* If the line has any text in it,
       save it on the history. */
    if (store_history && line_read && *line_read)
        add_history(line_read);

    return (line_read);
}

static int is_line_continued(const char *line, size_t *content_len) {
    size_t len = strlen(line);
    size_t end = len;
    size_t slash_count = 0;

    while (end > 0 && (line[end - 1] == ' ' || line[end - 1] == '\t')) {
        end--;
    }

    while (end > 0 && line[end - 1] == '\\') {
        slash_count++;
        end--;
    }

    if ((slash_count % 2) == 1) {
        *content_len = end + slash_count - 1;
        return 1;
    }

    *content_len = len;
    return 0;
}

static char *read_repl_input(lua_State *L, int *warned_prompt, int *warned_prompt_cont) {
    char *combined = NULL;
    size_t combined_len = 0;
    size_t combined_cap = 0;
    int first_line = 1;

    while (1) {
        size_t content_len;
        int continued;
        char *prompt = get_prompt_string(
            L, first_line ? "PROMPT" : "PROMPT_CONT", first_line ? "luna> " : "... ", first_line
                                                                                       ? warned_prompt
                                                                                       : warned_prompt_cont);
        char *segment = rl_gets(prompt ? prompt : "", 0);
        free(prompt);

        if (!segment) {
            if (combined) {
                if (!append_char(&combined, &combined_len, &combined_cap, '\0')) {
                    free(combined);
                    return NULL;
                }
            }
            return combined;
        }

        continued = is_line_continued(segment, &content_len);

        if (!append_bytes(&combined, &combined_len, &combined_cap, segment, content_len)) {
            free(combined);
            return NULL;
        }

        if (continued) {
            if (!append_char(&combined, &combined_len, &combined_cap, '\n')) {
                free(combined);
                return NULL;
            }
            first_line = 0;
            continue;
        }

        if (!append_char(&combined, &combined_len, &combined_cap, '\0')) {
            free(combined);
            return NULL;
        }
        return combined;
    }
}

typedef struct FdSnapshot {
    int saved_stdin;
    int saved_stdout;
    int saved_stderr;
    int mem_buffer_written;
} FdSnapshot;

static void init_fd_snapshot(FdSnapshot *snap) {
    snap->saved_stdin = -1;
    snap->saved_stdout = -1;
    snap->saved_stderr = -1;
    snap->mem_buffer_written = 0;
}

static int ensure_saved_fd(int target_fd, int *slot) {
    if (*slot >= 0) {
        return 1;
    }
    *slot = dup(target_fd);
    return *slot >= 0;
}

static const char *get_lua_cwd(lua_State *L) {
    const char *cwd = ".";
    lua_getglobal(L, "G_CWD");
    if (lua_isstring(L, -1)) {
        cwd = lua_tostring(L, -1);
    }
    if (!cwd || !*cwd) {
        cwd = ".";
    }
    lua_pop(L, 1);
    return cwd;
}

static int resolve_path_with_context(lua_State *L, const char *target, char *out, size_t out_size) {
    const char *cwd;
    const char *home;

    if (!target) {
        return 0;
    }
    cwd = get_lua_cwd(L);

    if (!*target) {
        return snprintf(out, out_size, "%s", cwd) < (int)out_size;
    }
    if (target[0] == '/') {
        return snprintf(out, out_size, "%s", target) < (int)out_size;
    }
    if (target[0] == '~') {
        home = getenv("HOME");
        if (home && *home) {
            if (target[1] == '\0') {
                return snprintf(out, out_size, "%s", home) < (int)out_size;
            }
            if (target[1] == '/') {
                return snprintf(out, out_size, "%s%s", home, target + 1) < (int)out_size;
            }
        }
    }

    return snprintf(out, out_size, "%s/%s", cwd, target) < (int)out_size;
}

static int lua_resolve_path(lua_State *L) {
    const char *target = luaL_checkstring(L, 1);
    char out[PATH_MAX];

    if (!resolve_path_with_context(L, target, out, sizeof(out))) {
        lua_pushnil(L);
        lua_pushstring(L, "path too long");
        return 2;
    }
    lua_pushstring(L, out);
    return 1;
}

static int resolve_redirection_path(lua_State *L, const char *target, char *out, size_t out_size) {
    return resolve_path_with_context(L, target, out, out_size);
}

static int expand_history_event(const char *line, char **expanded_out, char *err, size_t err_size) {
    int target_id = 0;
    int last_id;
    HIST_ENTRY *entry = NULL;

    *expanded_out = NULL;
    if (!line || line[0] != '!') {
        return 0;
    }

    if (!line[1]) {
        snprintf(err, err_size, "history: invalid event");
        return -1;
    }

    if (history_length <= 0) {
        snprintf(err, err_size, "history: event not found");
        return -1;
    }
    last_id = history_base + history_length - 1;

    if (strcmp(line, "!!") == 0) {
        target_id = last_id;
    } else if (line[1] == '-') {
        char *end = NULL;
        long n = strtol(line + 2, &end, 10);
        if (line[2] == '\0' || *end != '\0' || n <= 0) {
            snprintf(err, err_size, "history: invalid event '%s'", line);
            return -1;
        }
        target_id = last_id - (int)n + 1;
    } else if (isdigit((unsigned char)line[1])) {
        char *end = NULL;
        long n = strtol(line + 1, &end, 10);
        if (*end != '\0' || n <= 0) {
            snprintf(err, err_size, "history: invalid event '%s'", line);
            return -1;
        }
        target_id = (int)n;
    } else {
        snprintf(err, err_size, "history: unsupported event '%s'", line);
        return -1;
    }

    if (target_id < history_base || target_id > last_id) {
        snprintf(err, err_size, "history: event not found: %s", line);
        return -1;
    }

    entry = history_get(target_id);
    if (!entry || !entry->line) {
        snprintf(err, err_size, "history: event not found: %s", line);
        return -1;
    }

    *expanded_out = dup_cstr(entry->line);
    if (!*expanded_out) {
        snprintf(err, err_size, "history: out of memory");
        return -1;
    }
    return 1;
}

static int apply_redirections(
    lua_State *L, const CommandNode *cmd, FdSnapshot *snap, char *err, size_t err_size) {
    int i;
    for (i = 0; i < cmd->redir_count; i++) {
        int fd = -1;
        int flags = 0;
        int target_fd = -1;
        int is_mem_target = 0;
        char path[PATH_MAX];
        Redirection *r = &cmd->redirs[i];
        const char *buffer_path = NULL;

        if (r->type == REDIR_ERR_TO_OUT) {
            if (!ensure_saved_fd(STDERR_FILENO, &snap->saved_stderr)) {
                snprintf(err, err_size, "failed to save stderr: %s", strerror(errno));
                return 0;
            }
            if (dup2(STDOUT_FILENO, STDERR_FILENO) < 0) {
                snprintf(err, err_size, "failed to redirect stderr: %s", strerror(errno));
                return 0;
            }
            continue;
        }

        if (r->target && (strcmp(r->target, ":@mem") == 0 || strcmp(r->target, ":@file") == 0)) {
            if (!is_buffer_target_word(r->target, &buffer_path, &is_mem_target)) {
                snprintf(err, err_size, "failed to resolve buffer target '%s'", r->target);
                return 0;
            }
            if (snprintf(path, sizeof(path), "%s", buffer_path) >= (int)sizeof(path)) {
                snprintf(err, err_size, "buffer path too long");
                return 0;
            }
        } else {
            if (!resolve_redirection_path(L, r->target, path, sizeof(path))) {
                snprintf(err, err_size, "redirection path too long");
                return 0;
            }
        }

        switch (r->type) {
            case REDIR_IN:
                flags = O_RDONLY;
                target_fd = STDIN_FILENO;
                break;
            case REDIR_OUT:
                flags = O_WRONLY | O_CREAT | O_TRUNC;
                target_fd = STDOUT_FILENO;
                break;
            case REDIR_OUT_APPEND:
                flags = O_WRONLY | O_CREAT | O_APPEND;
                target_fd = STDOUT_FILENO;
                break;
            case REDIR_ERR_OUT:
                flags = O_WRONLY | O_CREAT | O_TRUNC;
                target_fd = STDERR_FILENO;
                break;
            case REDIR_ERR_OUT_APPEND:
                flags = O_WRONLY | O_CREAT | O_APPEND;
                target_fd = STDERR_FILENO;
                break;
            default:
                snprintf(err, err_size, "unsupported redirection");
                return 0;
        }

        fd = open(path, flags, 0644);
        if (fd < 0) {
            snprintf(err, err_size, "failed to open '%s': %s", path, strerror(errno));
            return 0;
        }

        if (target_fd == STDIN_FILENO) {
            if (!ensure_saved_fd(STDIN_FILENO, &snap->saved_stdin)) {
                close(fd);
                snprintf(err, err_size, "failed to save stdin: %s", strerror(errno));
                return 0;
            }
        } else if (target_fd == STDOUT_FILENO) {
            if (!ensure_saved_fd(STDOUT_FILENO, &snap->saved_stdout)) {
                close(fd);
                snprintf(err, err_size, "failed to save stdout: %s", strerror(errno));
                return 0;
            }
        } else {
            if (!ensure_saved_fd(STDERR_FILENO, &snap->saved_stderr)) {
                close(fd);
                snprintf(err, err_size, "failed to save stderr: %s", strerror(errno));
                return 0;
            }
        }

        if (dup2(fd, target_fd) < 0) {
            close(fd);
            snprintf(err, err_size, "failed to redirect fd %d: %s", target_fd, strerror(errno));
            return 0;
        }
        close(fd);

        if (is_mem_target && (r->type == REDIR_OUT || r->type == REDIR_OUT_APPEND || r->type == REDIR_ERR_OUT
                              || r->type == REDIR_ERR_OUT_APPEND)) {
            snap->mem_buffer_written = 1;
        }
    }
    return 1;
}

static void restore_redirections(FdSnapshot *snap) {
    if (snap->saved_stdin >= 0) {
        dup2(snap->saved_stdin, STDIN_FILENO);
        close(snap->saved_stdin);
        snap->saved_stdin = -1;
    }
    if (snap->saved_stdout >= 0) {
        dup2(snap->saved_stdout, STDOUT_FILENO);
        close(snap->saved_stdout);
        snap->saved_stdout = -1;
    }
    if (snap->saved_stderr >= 0) {
        dup2(snap->saved_stderr, STDERR_FILENO);
        close(snap->saved_stderr);
        snap->saved_stderr = -1;
    }
    if (snap->mem_buffer_written) {
        clamp_memory_buffer();
        snap->mem_buffer_written = 0;
    }
}

static int has_glob_chars(const char *s) {
    if (!s) {
        return 0;
    }
    return strchr(s, '*') || strchr(s, '?') || strchr(s, '[');
}

static int append_word(char ***items, int *count, const char *s) {
    char **next;
    char *copy = dup_cstr(s);
    if (!copy) {
        return 0;
    }
    next = realloc(*items, sizeof(char *) * (size_t)(*count + 1));
    if (!next) {
        free(copy);
        return 0;
    }
    *items = next;
    (*items)[*count] = copy;
    (*count)++;
    return 1;
}

static int qsort_strcmp(const void *a, const void *b) {
    const char *const *sa = (const char *const *)a;
    const char *const *sb = (const char *const *)b;
    return strcmp(*sa, *sb);
}

static int split_glob_arg(const char *arg, char *dir_part, size_t dir_size, const char **base_out) {
    const char *slash = strrchr(arg, '/');
    if (!slash) {
        if (snprintf(dir_part, dir_size, ".") >= (int)dir_size) {
            return 0;
        }
        *base_out = arg;
        return 1;
    }

    if (slash == arg) {
        if (snprintf(dir_part, dir_size, "/") >= (int)dir_size) {
            return 0;
        }
    } else {
        size_t n = (size_t)(slash - arg);
        if (n + 1 > dir_size) {
            return 0;
        }
        memcpy(dir_part, arg, n);
        dir_part[n] = '\0';
    }
    *base_out = slash + 1;
    return 1;
}

static int expand_glob_arg(lua_State *L, const char *arg, char ***out_items, int *out_count) {
    DIR *dir = NULL;
    struct dirent *entry;
    char abs_dir[PATH_MAX];
    char dir_part[PATH_MAX];
    const char *base = NULL;
    char **matches = NULL;
    int match_count = 0;
    int i;

    if (!split_glob_arg(arg, dir_part, sizeof(dir_part), &base)) {
        return append_word(out_items, out_count, arg);
    }
    if (!resolve_path_with_context(L, dir_part, abs_dir, sizeof(abs_dir))) {
        return append_word(out_items, out_count, arg);
    }

    dir = opendir(abs_dir);
    if (!dir) {
        return append_word(out_items, out_count, arg);
    }

    while ((entry = readdir(dir)) != NULL) {
        char composed[PATH_MAX];
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (fnmatch(base, entry->d_name, 0) != 0) {
            continue;
        }
        if (strcmp(dir_part, ".") == 0) {
            if (snprintf(composed, sizeof(composed), "%s", entry->d_name) >= (int)sizeof(composed)) {
                continue;
            }
        } else if (strcmp(dir_part, "/") == 0) {
            if (snprintf(composed, sizeof(composed), "/%s", entry->d_name) >= (int)sizeof(composed)) {
                continue;
            }
        } else {
            if (snprintf(composed, sizeof(composed), "%s/%s", dir_part, entry->d_name) >= (int)sizeof(composed)) {
                continue;
            }
        }
        if (!append_word(&matches, &match_count, composed)) {
            closedir(dir);
            free_argv_list(matches, match_count);
            return 0;
        }
    }
    closedir(dir);

    if (match_count == 0) {
        free_argv_list(matches, match_count);
        return append_word(out_items, out_count, arg);
    }

    qsort(matches, (size_t)match_count, sizeof(char *), qsort_strcmp);
    for (i = 0; i < match_count; i++) {
        if (!append_word(out_items, out_count, matches[i])) {
            free_argv_list(matches, match_count);
            return 0;
        }
    }
    free_argv_list(matches, match_count);
    return 1;
}

static int expand_builtin_globs(lua_State *L, char ***argv_ptr, int *argc_ptr, char *err, size_t err_size) {
    char **src = *argv_ptr;
    int src_argc = *argc_ptr;
    char **dst = NULL;
    int dst_argc = 0;
    int i;

    if (src_argc <= 1) {
        return 1;
    }

    if (!append_word(&dst, &dst_argc, src[0])) {
        snprintf(err, err_size, "out of memory");
        return 0;
    }

    for (i = 1; i < src_argc; i++) {
        const char *arg = src[i];
        if (has_glob_chars(arg)) {
            if (!expand_glob_arg(L, arg, &dst, &dst_argc)) {
                free_argv_list(dst, dst_argc);
                snprintf(err, err_size, "out of memory");
                return 0;
            }
        } else {
            if (!append_word(&dst, &dst_argc, arg)) {
                free_argv_list(dst, dst_argc);
                snprintf(err, err_size, "out of memory");
                return 0;
            }
        }
    }

    free_argv_list(src, src_argc);
    *argv_ptr = dst;
    *argc_ptr = dst_argc;
    return 1;
}

static int eval_lua_expr_to_string(lua_State *L, const char *expr, char **out, char *err, size_t err_size) {
    char *chunk = NULL;
    size_t chunk_len = 0;
    size_t chunk_cap = 0;
    int status;
    const char *result_str;

    *out = NULL;

    if (!append_bytes(&chunk, &chunk_len, &chunk_cap, "return ", 7)
        || !append_bytes(&chunk, &chunk_len, &chunk_cap, expr, strlen(expr))
        || !append_char(&chunk, &chunk_len, &chunk_cap, '\0')) {
        free(chunk);
        snprintf(err, err_size, "out of memory");
        return 0;
    }

    status = luaL_loadstring(L, chunk);
    free(chunk);
    if (status != LUA_OK) {
        snprintf(err, err_size, "command substitution load error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
        return 0;
    }

    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        snprintf(err, err_size, "command substitution runtime error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
        return 0;
    }

    luaL_tolstring(L, -1, NULL);
    result_str = lua_tostring(L, -1);
    *out = dup_cstr(result_str ? result_str : "");
    lua_pop(L, 2);

    if (!*out) {
        snprintf(err, err_size, "out of memory");
        return 0;
    }
    return 1;
}

static int expand_backticks_in_text(lua_State *L, const char *input, char **out, char *err, size_t err_size) {
    char *buf = NULL;
    size_t buf_len = 0;
    size_t buf_cap = 0;
    size_t i = 0;

    *out = NULL;
    if (!input) {
        *out = dup_cstr("");
        return *out != NULL;
    }

    while (input[i]) {
        if (input[i] == '`') {
            char *expr = NULL;
            size_t expr_len = 0;
            size_t expr_cap = 0;
            char *subst = NULL;

            i++;
            while (input[i] && input[i] != '`') {
                if (input[i] == '\\' && input[i + 1] == '`') {
                    if (!append_char(&expr, &expr_len, &expr_cap, '`')) {
                        free(expr);
                        free(buf);
                        snprintf(err, err_size, "out of memory");
                        return 0;
                    }
                    i += 2;
                    continue;
                }
                if (!append_char(&expr, &expr_len, &expr_cap, input[i])) {
                    free(expr);
                    free(buf);
                    snprintf(err, err_size, "out of memory");
                    return 0;
                }
                i++;
            }
            if (input[i] != '`') {
                free(expr);
                free(buf);
                snprintf(err, err_size, "unterminated command substitution");
                return 0;
            }
            i++;

            if (!append_char(&expr, &expr_len, &expr_cap, '\0')) {
                free(expr);
                free(buf);
                snprintf(err, err_size, "out of memory");
                return 0;
            }
            if (!eval_lua_expr_to_string(L, expr, &subst, err, err_size)) {
                free(expr);
                free(buf);
                return 0;
            }
            free(expr);

            if (!append_bytes(&buf, &buf_len, &buf_cap, subst, strlen(subst))) {
                free(subst);
                free(buf);
                snprintf(err, err_size, "out of memory");
                return 0;
            }
            free(subst);
            continue;
        }

        if (input[i] == '\\' && input[i + 1] == '`') {
            if (!append_char(&buf, &buf_len, &buf_cap, '`')) {
                free(buf);
                snprintf(err, err_size, "out of memory");
                return 0;
            }
            i += 2;
            continue;
        }

        if (!append_char(&buf, &buf_len, &buf_cap, input[i])) {
            free(buf);
            snprintf(err, err_size, "out of memory");
            return 0;
        }
        i++;
    }

    if (!append_char(&buf, &buf_len, &buf_cap, '\0')) {
        free(buf);
        snprintf(err, err_size, "out of memory");
        return 0;
    }
    *out = buf;
    return 1;
}

static int expand_backticks_for_lua_chunk(const char *input, char **out, char *err, size_t err_size) {
    size_t i = 0;
    size_t n;
    int in_single = 0;
    int in_double = 0;
    char *buf = NULL;
    size_t len = 0;
    size_t cap = 0;

    if (!input) {
        *out = NULL;
        return 1;
    }

    n = strlen(input);
    while (i < n) {
        char c = input[i];
        if (!in_single && c == '"') {
            in_double = !in_double;
            if (!append_char(&buf, &len, &cap, c)) {
                snprintf(err, err_size, "out of memory");
                free(buf);
                return 0;
            }
            i++;
            continue;
        }
        if (!in_double && c == '\'') {
            in_single = !in_single;
            if (!append_char(&buf, &len, &cap, c)) {
                snprintf(err, err_size, "out of memory");
                free(buf);
                return 0;
            }
            i++;
            continue;
        }
        if (in_double && c == '\\' && i + 1 < n) {
            if (!append_char(&buf, &len, &cap, c) || !append_char(&buf, &len, &cap, input[i + 1])) {
                snprintf(err, err_size, "out of memory");
                free(buf);
                return 0;
            }
            i += 2;
            continue;
        }
        if (!in_single && !in_double && c == '`') {
            size_t j = i + 1;
            size_t expr_start;
            size_t expr_len;
            while (j < n && input[j] != '`') {
                j++;
            }
            if (j >= n) {
                snprintf(err, err_size, "unterminated command substitution");
                free(buf);
                return 0;
            }
            expr_start = i + 1;
            expr_len = j - expr_start;
            if (!append_char(&buf, &len, &cap, '(')
                || !append_bytes(&buf, &len, &cap, input + expr_start, expr_len)
                || !append_char(&buf, &len, &cap, ')')) {
                snprintf(err, err_size, "out of memory");
                free(buf);
                return 0;
            }
            i = j + 1;
            continue;
        }
        if (!append_char(&buf, &len, &cap, c)) {
            snprintf(err, err_size, "out of memory");
            free(buf);
            return 0;
        }
        i++;
    }

    if (!append_char(&buf, &len, &cap, '\0')) {
        snprintf(err, err_size, "out of memory");
        free(buf);
        return 0;
    }
    *out = buf;
    return 1;
}

static int line_compiles_as_lua(lua_State *L, const char *input) {
    int status;
    if (!input) {
        return 0;
    }
    status = luaL_loadstring(L, input);
    if (status == LUA_OK) {
        lua_pop(L, 1);
        return 1;
    }
    lua_pop(L, 1);
    return 0;
}

static int line_looks_like_lua_chunk(lua_State *L, const char *input) {
    static const char *keywords[] = {
        "if", "for", "while", "repeat", "function", "local", "do", "return", "break"
    };
    const char *p = input;
    int i;

    if (!input) {
        return 0;
    }
    while (*p && isspace((unsigned char)*p)) {
        p++;
    }

    if (line_compiles_as_lua(L, input)) {
        return 1;
    }

    for (i = 0; i < (int)(sizeof(keywords) / sizeof(keywords[0])); i++) {
        size_t n = strlen(keywords[i]);
        if (strncmp(p, keywords[i], n) == 0 && (p[n] == '\0' || isspace((unsigned char)p[n]))) {
            return 1;
        }
    }

    for (; *p; p++) {
        if (*p == '=' && p[1] != '=' && (p == input || p[-1] != '<') && p[-1] != '>' && p[-1] != '~') {
            return 1;
        }
    }

    return 0;
}

static int execute_raw_lua_chunk(lua_State *L, const char *chunk_text) {
    char *expanded_chunk = NULL;
    char chunk_subst_err[MAX_PARSE_ERR];

    if (!expand_backticks_for_lua_chunk(chunk_text, &expanded_chunk, chunk_subst_err, sizeof(chunk_subst_err))) {
        fprintf(stderr, "Substitution error: %s\n", chunk_subst_err);
        return 0;
    }

    if (luaL_dostring(L, expanded_chunk ? expanded_chunk : chunk_text) != LUA_OK) {
        fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        free(expanded_chunk);
        return 0;
    }

    free(expanded_chunk);
    return 1;
}

static int expand_backticks_in_argv(lua_State *L, char **argv, int argc, char *err, size_t err_size) {
    int i;
    for (i = 1; i < argc; i++) {
        char *expanded = NULL;
        if (!expand_backticks_in_text(L, argv[i], &expanded, err, err_size)) {
            return 0;
        }
        free(argv[i]);
        argv[i] = expanded;
    }
    return 1;
}

static int clone_and_expand_redirs(
    lua_State *L, const CommandNode *cmd, Redirection **out_redirs, int *out_count, char *err, size_t err_size) {
    Redirection *arr = NULL;
    int i;

    *out_redirs = NULL;
    *out_count = 0;
    if (cmd->redir_count <= 0) {
        return 1;
    }

    arr = calloc((size_t)cmd->redir_count, sizeof(Redirection));
    if (!arr) {
        snprintf(err, err_size, "out of memory");
        return 0;
    }

    for (i = 0; i < cmd->redir_count; i++) {
        arr[i].type = cmd->redirs[i].type;
        if (cmd->redirs[i].target) {
            if (!expand_backticks_in_text(L, cmd->redirs[i].target, &arr[i].target, err, err_size)) {
                int j;
                for (j = 0; j <= i; j++) {
                    free(arr[j].target);
                }
                free(arr);
                return 0;
            }
        } else {
            arr[i].target = NULL;
        }
    }

    *out_redirs = arr;
    *out_count = cmd->redir_count;
    return 1;
}

static void free_redirs_copy(Redirection *redirs, int count) {
    int i;
    if (!redirs) {
        return;
    }
    for (i = 0; i < count; i++) {
        free(redirs[i].target);
    }
    free(redirs);
}

static void tui_move_cursor(int row, int col) {
    if (row < 1) {
        row = 1;
    }
    if (col < 1) {
        col = 1;
    }
    printf("\033[%d;%dH", row, col);
}

static void tui_print_clipped(int row, int col, int width, const char *text) {
    int n = 0;
    const char *p = text ? text : "";
    if (width <= 0) {
        return;
    }
    tui_move_cursor(row, col);
    while (*p && n < width) {
        putchar(*p);
        p++;
        n++;
    }
}

static int is_tui_mode_enabled(lua_State *L) {
    int enabled = 0;
    lua_getglobal(L, "TUI_MODE");
    enabled = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return enabled;
}

static int g_tui_initialized = 0;

static void render_tui(lua_State *L) {
    struct winsize ws;
    int rows = 24;
    int cols = 80;
    int left_w;
    int right_w;
    int top_h;
    int files_row_start;
    int files_row_end;
    int files_rows_available;
    int files_usable_width;
    int files_max_name_w = 1;
    int files_col_w;
    int files_cols;
    int history_row_start;
    int history_row_end;
    int cmd_row;
    const char *cwd;
    DIR *dir;
    struct dirent *entry;
    char **names = NULL;
    int name_count = 0;
    int i;
    HIST_ENTRY **hist_entries;
    int hist_count = 0;
    int hist_start = 0;

    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0) {
        if (ws.ws_row > 0) {
            rows = ws.ws_row;
        }
        if (ws.ws_col > 0) {
            cols = ws.ws_col;
        }
    }
    if (rows < 8 || cols < 40) {
        return;
    }

    left_w = (cols * 80) / 100;
    if (left_w < 20) {
        left_w = 20;
    }
    if (left_w > cols - 10) {
        left_w = cols - 10;
    }
    right_w = cols - left_w;
    if (right_w < 8) {
        right_w = 8;
        left_w = cols - right_w;
    }

    top_h = rows / 2;
    if (top_h < 3) {
        top_h = 3;
    }
    if (top_h > rows - 3) {
        top_h = rows - 3;
    }

    if (!g_tui_initialized) {
        printf("\033[2J\033[H");
        g_tui_initialized = 1;
    }

    for (i = 1; i <= rows; i++) {
        tui_move_cursor(i, left_w + 1);
        putchar('|');
    }
    for (i = 1; i <= left_w; i++) {
        tui_move_cursor(top_h + 1, i);
        putchar('-');
    }

    for (i = 1; i <= top_h; i++) {
        tui_move_cursor(i, 1);
        printf("%-*s", left_w, "");
    }
    for (i = 1; i <= rows; i++) {
        tui_move_cursor(i, left_w + 2);
        printf("%-*s", right_w - 1, "");
    }

    tui_print_clipped(1, 2, left_w - 3, "FILES");
    tui_print_clipped(top_h + 2, 2, left_w - 3, "COMMAND");
    tui_print_clipped(1, left_w + 3, right_w - 4, "HISTORY");

    cwd = get_lua_cwd(L);
    tui_print_clipped(1, 10, left_w - 12, cwd);

    files_row_start = 2;
    files_row_end = top_h;
    dir = opendir(cwd);
    if (dir) {
        while ((entry = readdir(dir)) != NULL) {
            char **next;
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            next = realloc(names, sizeof(char *) * (size_t)(name_count + 1));
            if (!next) {
                break;
            }
            names = next;
            names[name_count] = dup_cstr(entry->d_name);
            if (!names[name_count]) {
                break;
            }
            name_count++;
        }
        closedir(dir);
    }
    if (name_count > 1) {
        qsort(names, (size_t)name_count, sizeof(char *), qsort_strcmp);
    }

    files_rows_available = files_row_end - files_row_start + 1;
    files_usable_width = left_w - 3;
    for (i = 0; i < name_count; i++) {
        int n = (int)strlen(names[i]);
        if (n > files_max_name_w) {
            files_max_name_w = n;
        }
    }
    if (files_rows_available < 1) {
        files_rows_available = 1;
    }
    if (files_usable_width < 1) {
        files_usable_width = 1;
    }
    files_col_w = files_max_name_w + 2;
    if (files_col_w < 4) {
        files_col_w = 4;
    }
    files_cols = files_usable_width / files_col_w;
    if (files_cols < 1) {
        files_cols = 1;
    }
    if (files_cols > name_count) {
        files_cols = name_count;
    }

    for (i = 0; i < files_rows_available; i++) {
        int c;
        int row = files_row_start + i;
        for (c = 0; c < files_cols; c++) {
            int idx = i * files_cols + c;
            int col = 2 + (c * files_col_w);
            int cell_w = files_col_w - 1;
            if (idx >= name_count || col > left_w - 1) {
                break;
            }
            if (col + cell_w > left_w) {
                cell_w = left_w - col;
            }
            if (cell_w < 1) {
                continue;
            }
            tui_print_clipped(row, col, cell_w, names[idx]);
        }
    }
    for (i = 0; i < name_count; i++) {
        free(names[i]);
    }
    free(names);

    history_row_start = 2;
    history_row_end = rows;
    hist_entries = history_list();
    if (hist_entries) {
        while (hist_entries[hist_count]) {
            hist_count++;
        }
    }
    if (hist_count > 0) {
        int max_lines = history_row_end - history_row_start + 1;
        if (max_lines < 0) {
            max_lines = 0;
        }
        if (hist_count > max_lines) {
            hist_start = hist_count - max_lines;
        }
        for (i = hist_start; i < hist_count; i++) {
            char linebuf[512];
            int row = history_row_start + (i - hist_start);
            snprintf(
                linebuf, sizeof(linebuf), "%d %s", history_base + i, hist_entries[i]->line ? hist_entries[i]->line : "");
            tui_print_clipped(row, left_w + 3, right_w - 4, linebuf);
        }
    }

    cmd_row = rows;
    tui_move_cursor(cmd_row, 1);
    fflush(stdout);
}

static void build_lua_fallback_chunk(const CommandNode *cmd, char *out, size_t out_size) {
    int i;
    size_t used = 0;
    out[0] = '\0';
    for (i = 0; i < cmd->argc; i++) {
        int wrote;
        wrote = snprintf(out + used, out_size - used, "%s%s", i == 0 ? "" : " ", cmd->argv[i]);
        if (wrote < 0 || (size_t)wrote >= out_size - used) {
            break;
        }
        used += (size_t)wrote;
    }
}

static int execute_single_command(
    lua_State *L, const CommandNode *cmd, const char *original_line, int force_reconstructed_chunk) {
    int status, result;
    CommandNode effective = {0};
    char **expanded_argv = NULL;
    int expanded_argc = 0;
    int has_builtin = 0;
    int is_user_builtin = 0;
    char builtin_path[PATH_MAX];
    char fallback_chunk[1024];
    FdSnapshot snap;
    char redir_err[MAX_PARSE_ERR];
    char alias_err[MAX_PARSE_ERR];
    char glob_err[MAX_PARSE_ERR];
    char subst_err[MAX_PARSE_ERR];
    Redirection *expanded_redirs = NULL;
    int expanded_redir_count = 0;

    if (!expand_alias_argv(L, cmd, &expanded_argv, &expanded_argc, alias_err, sizeof(alias_err))) {
        fprintf(stderr, "Alias error: %s\n", alias_err);
        free_argv_list(expanded_argv, expanded_argc);
        return 0;
    }

    effective.argc = expanded_argc;
    effective.argv = expanded_argv;
    effective.redir_count = cmd->redir_count;
    effective.redirs = cmd->redirs;

    has_builtin = resolve_builtin_path_for_name(
        effective.argv[0], builtin_path, sizeof(builtin_path), &is_user_builtin);

    if (has_builtin) {
        if (!expand_backticks_in_argv(L, expanded_argv, expanded_argc, subst_err, sizeof(subst_err))) {
            fprintf(stderr, "Substitution error: %s\n", subst_err);
            free_argv_list(expanded_argv, expanded_argc);
            return 0;
        }
        if (!clone_and_expand_redirs(
                L, cmd, &expanded_redirs, &expanded_redir_count, subst_err, sizeof(subst_err))) {
            fprintf(stderr, "Substitution error: %s\n", subst_err);
            free_argv_list(expanded_argv, expanded_argc);
            return 0;
        }
        effective.redirs = expanded_redirs;
        effective.redir_count = expanded_redir_count;

        if (!expand_builtin_globs(L, &expanded_argv, &expanded_argc, glob_err, sizeof(glob_err))) {
            fprintf(stderr, "Glob error: %s\n", glob_err);
            free_redirs_copy(expanded_redirs, expanded_redir_count);
            free_argv_list(expanded_argv, expanded_argc);
            return 0;
        }
        effective.argc = expanded_argc;
        effective.argv = expanded_argv;
    }

    set_lua_command_globals(L, &effective);

    if (has_builtin) {
        lua_pushstring(L, is_user_builtin ? "user-builtin" : "core-builtin");
        lua_setglobal(L, "CMD_SOURCE");
        lua_pushstring(L, builtin_path);
        lua_setglobal(L, "CMD_PATH");
    } else {
        lua_pushstring(L, "lua-fallback");
        lua_setglobal(L, "CMD_SOURCE");
        lua_pushnil(L);
        lua_setglobal(L, "CMD_PATH");
    }

    init_fd_snapshot(&snap);
    if (!apply_redirections(L, &effective, &snap, redir_err, sizeof(redir_err))) {
        fprintf(stderr, "Redirection error: %s\n", redir_err);
        restore_redirections(&snap);
        free_redirs_copy(expanded_redirs, expanded_redir_count);
        free_argv_list(expanded_argv, expanded_argc);
        return 0;
    }

    if (has_builtin) {
        status = luaL_loadfile(L, builtin_path);
    } else {
        status = 1;
    }
    if (!status && has_builtin) {
        result = lua_pcall(L, 0, LUA_MULTRET, 0);
        if (result) {
            fprintf(stderr, "Failed to run script: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
        restore_redirections(&snap);
        free_redirs_copy(expanded_redirs, expanded_redir_count);
        free_argv_list(expanded_argv, expanded_argc);
        return 1;
    } else {
        if (!has_builtin) {
            const char *chunk = original_line;
            if (force_reconstructed_chunk || cmd->redir_count > 0) {
                build_lua_fallback_chunk(&effective, fallback_chunk, sizeof(fallback_chunk));
                chunk = fallback_chunk;
            }
            if (!execute_raw_lua_chunk(L, chunk)) {
                restore_redirections(&snap);
                free_redirs_copy(expanded_redirs, expanded_redir_count);
                free_argv_list(expanded_argv, expanded_argc);
                return 0;
            }
        } else {
            const char *load_err = lua_tostring(L, -1);
            fprintf(stderr,
                    "Failed to load builtin '%s': %s\n",
                    effective.argv[0],
                    load_err ? load_err : "unknown error");
            lua_pop(L, 1);
        }
        restore_redirections(&snap);
        free_redirs_copy(expanded_redirs, expanded_redir_count);
        free_argv_list(expanded_argv, expanded_argc);
        return 1;
    }
}

static int execute_pipeline(lua_State *L, const PipelineNode *pipeline) {
    int i;
    int n = pipeline->command_count;
    int has_text_pipe = 0;
    int has_lua_pipe = 0;
    int *pipefds = NULL;
    pid_t *pids = NULL;
    int success = 1;

    if (n <= 0) {
        return 1;
    }
    if (n == 1) {
        return execute_single_command(L, &pipeline->commands[0], NULL, 1);
    }
    if (pipeline->pipe_count != (n - 1)) {
        fprintf(stderr, "Pipeline error: invalid pipeline structure\n");
        return 0;
    }

    for (i = 0; i < pipeline->pipe_count; i++) {
        if (pipeline->pipes[i] == PIPE_LUA) {
            has_lua_pipe = 1;
        } else {
            has_text_pipe = 1;
        }
    }
    if (has_lua_pipe && has_text_pipe) {
        int first_lua = -1;
        int first_text = -1;
        int invalid = 0;
        int lua_cmds;
        int i2;
        int outfd = -1;
        int saved_stdout = -1;
        int ok = 1;
        int ref = LUA_NOREF;
        char fallback_chunk[1024];
        char tmp_path[] = "/tmp/lunacmd-luapipe-XXXXXX";

        for (i2 = 0; i2 < pipeline->pipe_count; i2++) {
            if (first_lua < 0 && pipeline->pipes[i2] == PIPE_LUA) {
                first_lua = i2;
            }
            if (pipeline->pipes[i2] == PIPE_TEXT) {
                first_text = i2;
                if (first_text == i2) {
                    /* first text only */
                }
            }
        }
        if (first_text < 0 || first_lua < 0) {
            fprintf(stderr, "Pipeline error: invalid mixed pipeline structure\n");
            return 0;
        }

        if (first_text < first_lua) {
            int boundary = first_lua;
            int ok = 1;
            int ref = LUA_NOREF;
            int saved_stdin = -1;
            int outfd = -1;
            int saved_stdout = -1;
            char fallback_chunk[1024];
            char tmp_path[] = "/tmp/lunacmd-textpipe-XXXXXX";

            for (i2 = first_lua + 1; i2 < pipeline->pipe_count; i2++) {
                if (pipeline->pipes[i2] == PIPE_TEXT) {
                    invalid = 1;
                    break;
                }
            }
            if (invalid) {
                fprintf(stderr, "Pipeline error: mixed pipelines must use a single transition (:|... then :||..., or :||... then :|...)\n");
                return 0;
            }

            if (boundary > 0) {
                PipelineNode text_prefix;
                text_prefix.command_count = boundary;
                text_prefix.commands = pipeline->commands;
                text_prefix.pipe_count = boundary - 1;
                text_prefix.pipes = pipeline->pipes;

                outfd = mkstemp(tmp_path);
                if (outfd < 0) {
                    fprintf(stderr, "Pipeline error: temp file creation failed: %s\n", strerror(errno));
                    return 0;
                }
                unlink(tmp_path);

                saved_stdout = dup(STDOUT_FILENO);
                if (saved_stdout < 0 || dup2(outfd, STDOUT_FILENO) < 0) {
                    if (saved_stdout >= 0) {
                        close(saved_stdout);
                    }
                    close(outfd);
                    fprintf(stderr, "Pipeline error: stdout capture setup failed: %s\n", strerror(errno));
                    return 0;
                }

                ok = execute_pipeline(L, &text_prefix);
                fflush(stdout);
                dup2(saved_stdout, STDOUT_FILENO);
                close(saved_stdout);
                saved_stdout = -1;
                if (!ok) {
                    close(outfd);
                    return 0;
                }
                lseek(outfd, 0, SEEK_SET);
            }

            lua_pushboolean(L, 1);
            lua_setglobal(L, "LUA_PIPE_ACTIVE");
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_IN");
            lua_pushboolean(L, boundary == (n - 1) ? 1 : 0);
            lua_setglobal(L, "LUA_PIPE_LAST");
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_OUT");

            if (outfd >= 0) {
                saved_stdin = dup(STDIN_FILENO);
                if (saved_stdin < 0 || dup2(outfd, STDIN_FILENO) < 0) {
                    if (saved_stdin >= 0) {
                        close(saved_stdin);
                    }
                    close(outfd);
                    lua_pushnil(L);
                    lua_setglobal(L, "LUA_PIPE_IN");
                    lua_pushnil(L);
                    lua_setglobal(L, "LUA_PIPE_OUT");
                    lua_pushnil(L);
                    lua_setglobal(L, "LUA_PIPE_LAST");
                    lua_pushboolean(L, 0);
                    lua_setglobal(L, "LUA_PIPE_ACTIVE");
                    fprintf(stderr, "Pipeline error: stdin capture setup failed: %s\n", strerror(errno));
                    return 0;
                }
                close(outfd);
                outfd = -1;
            }

            build_lua_fallback_chunk(&pipeline->commands[boundary], fallback_chunk, sizeof(fallback_chunk));
            ok = execute_single_command(L, &pipeline->commands[boundary], fallback_chunk, 1);

            if (saved_stdin >= 0) {
                dup2(saved_stdin, STDIN_FILENO);
                close(saved_stdin);
            }
            if (!ok) {
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_IN");
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_OUT");
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_LAST");
                lua_pushboolean(L, 0);
                lua_setglobal(L, "LUA_PIPE_ACTIVE");
                return 0;
            }

            lua_getglobal(L, "LUA_PIPE_OUT");
            ref = luaL_ref(L, LUA_REGISTRYINDEX);

            for (i2 = boundary + 1; i2 < n; i2++) {
                if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
                    lua_setglobal(L, "LUA_PIPE_IN");
                } else {
                    lua_pushnil(L);
                    lua_setglobal(L, "LUA_PIPE_IN");
                }
                lua_pushboolean(L, i2 == (n - 1) ? 1 : 0);
                lua_setglobal(L, "LUA_PIPE_LAST");
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_OUT");

                build_lua_fallback_chunk(&pipeline->commands[i2], fallback_chunk, sizeof(fallback_chunk));
                if (!execute_single_command(L, &pipeline->commands[i2], fallback_chunk, 1)) {
                    ok = 0;
                    break;
                }

                if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                    luaL_unref(L, LUA_REGISTRYINDEX, ref);
                }
                lua_getglobal(L, "LUA_PIPE_OUT");
                ref = luaL_ref(L, LUA_REGISTRYINDEX);
            }

            if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                luaL_unref(L, LUA_REGISTRYINDEX, ref);
            }
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_IN");
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_OUT");
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_LAST");
            lua_pushboolean(L, 0);
            lua_setglobal(L, "LUA_PIPE_ACTIVE");
            return ok;
        }

        for (i2 = first_text + 1; i2 < pipeline->pipe_count; i2++) {
            if (pipeline->pipes[i2] == PIPE_LUA) {
                invalid = 1;
                break;
            }
        }
        if (invalid) {
            fprintf(stderr, "Pipeline error: mixed pipelines must use a single transition (:|... then :||..., or :||... then :|...)\n");
            return 0;
        }

        lua_cmds = first_text + 1;
        outfd = mkstemp(tmp_path);
        if (outfd < 0) {
            fprintf(stderr, "Pipeline error: temp file creation failed: %s\n", strerror(errno));
            return 0;
        }
        unlink(tmp_path);

        saved_stdout = dup(STDOUT_FILENO);
        if (saved_stdout < 0 || dup2(outfd, STDOUT_FILENO) < 0) {
            if (saved_stdout >= 0) {
                close(saved_stdout);
            }
            close(outfd);
            fprintf(stderr, "Pipeline error: stdout capture setup failed: %s\n", strerror(errno));
            return 0;
        }

        lua_pushboolean(L, 1);
        lua_setglobal(L, "LUA_PIPE_ACTIVE");
        for (i2 = 0; i2 < lua_cmds; i2++) {
            if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
                lua_setglobal(L, "LUA_PIPE_IN");
            } else {
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_IN");
            }
            lua_pushboolean(L, i2 == (lua_cmds - 1) ? 1 : 0);
            lua_setglobal(L, "LUA_PIPE_LAST");
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_OUT");

            build_lua_fallback_chunk(&pipeline->commands[i2], fallback_chunk, sizeof(fallback_chunk));
            if (!execute_single_command(L, &pipeline->commands[i2], fallback_chunk, 1)) {
                ok = 0;
                break;
            }

            if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                luaL_unref(L, LUA_REGISTRYINDEX, ref);
            }
            lua_getglobal(L, "LUA_PIPE_OUT");
            ref = luaL_ref(L, LUA_REGISTRYINDEX);
        }
        if (ref != LUA_NOREF && ref != LUA_REFNIL) {
            luaL_unref(L, LUA_REGISTRYINDEX, ref);
        }
        lua_pushnil(L);
        lua_setglobal(L, "LUA_PIPE_IN");
        lua_pushnil(L);
        lua_setglobal(L, "LUA_PIPE_OUT");
        lua_pushnil(L);
        lua_setglobal(L, "LUA_PIPE_LAST");
        lua_pushboolean(L, 0);
        lua_setglobal(L, "LUA_PIPE_ACTIVE");

        fflush(stdout);
        dup2(saved_stdout, STDOUT_FILENO);
        close(saved_stdout);
        saved_stdout = -1;
        lseek(outfd, 0, SEEK_SET);

        if (!ok) {
            close(outfd);
            return 0;
        }

        {
            int start = lua_cmds;
            int m = n - start;
            int *tpipes = NULL;
            pid_t *tpids = NULL;
            int ti;
            int tsuccess = 1;

            if (m <= 0) {
                close(outfd);
                return 1;
            }
            if (m == 1) {
                int saved_stdin = dup(STDIN_FILENO);
                if (saved_stdin < 0 || dup2(outfd, STDIN_FILENO) < 0) {
                    if (saved_stdin >= 0) {
                        close(saved_stdin);
                    }
                    close(outfd);
                    return 0;
                }
                close(outfd);
                ok = execute_single_command(L, &pipeline->commands[start], NULL, 1);
                dup2(saved_stdin, STDIN_FILENO);
                close(saved_stdin);
                return ok;
            }

            tpipes = calloc((size_t)(2 * (m - 1)), sizeof(int));
            tpids = calloc((size_t)m, sizeof(pid_t));
            if (!tpipes || !tpids) {
                close(outfd);
                free(tpipes);
                free(tpids);
                return 0;
            }
            for (ti = 0; ti < m - 1; ti++) {
                if (pipe(&tpipes[2 * ti]) < 0) {
                    tsuccess = 0;
                    break;
                }
            }
            if (!tsuccess) {
                for (ti = 0; ti < 2 * (m - 1); ti++) {
                    if (tpipes[ti] > 0) {
                        close(tpipes[ti]);
                    }
                }
                close(outfd);
                free(tpipes);
                free(tpids);
                return 0;
            }

            for (ti = 0; ti < m; ti++) {
                pid_t pid = fork();
                if (pid < 0) {
                    tsuccess = 0;
                    break;
                }
                if (pid == 0) {
                    int j;
                    char fb[1024];
                    const CommandNode *cmd = &pipeline->commands[start + ti];

                    if (ti == 0) {
                        dup2(outfd, STDIN_FILENO);
                    } else {
                        dup2(tpipes[2 * (ti - 1)], STDIN_FILENO);
                    }
                    if (ti < m - 1) {
                        dup2(tpipes[2 * ti + 1], STDOUT_FILENO);
                    }
                    close(outfd);
                    for (j = 0; j < 2 * (m - 1); j++) {
                        close(tpipes[j]);
                    }
                    build_lua_fallback_chunk(cmd, fb, sizeof(fb));
                    {
                        int okc = execute_single_command(L, cmd, fb, 1);
                        lua_close(L);
                        exit(okc ? 0 : 1);
                    }
                }
                tpids[ti] = pid;
            }

            close(outfd);
            for (ti = 0; ti < 2 * (m - 1); ti++) {
                close(tpipes[ti]);
            }
            if (!tsuccess) {
                for (ti = 0; ti < m; ti++) {
                    if (tpids[ti] > 0) {
                        waitpid(tpids[ti], NULL, 0);
                    }
                }
                free(tpipes);
                free(tpids);
                return 0;
            }
            for (ti = 0; ti < m; ti++) {
                int st;
                if (tpids[ti] > 0 && waitpid(tpids[ti], &st, 0) < 0) {
                    tsuccess = 0;
                }
            }
            free(tpipes);
            free(tpids);
            return tsuccess;
        }
    }
    if (has_lua_pipe) {
        int ref = LUA_NOREF;
        lua_pushboolean(L, 1);
        lua_setglobal(L, "LUA_PIPE_ACTIVE");
        for (i = 0; i < n; i++) {
            char fallback_chunk[1024];
            int ok;

            if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
                lua_setglobal(L, "LUA_PIPE_IN");
            } else {
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_IN");
            }
            lua_pushboolean(L, i == (n - 1) ? 1 : 0);
            lua_setglobal(L, "LUA_PIPE_LAST");
            lua_pushnil(L);
            lua_setglobal(L, "LUA_PIPE_OUT");

            build_lua_fallback_chunk(&pipeline->commands[i], fallback_chunk, sizeof(fallback_chunk));
            ok = execute_single_command(L, &pipeline->commands[i], fallback_chunk, 1);
            if (!ok) {
                if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                    luaL_unref(L, LUA_REGISTRYINDEX, ref);
                }
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_IN");
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_OUT");
                lua_pushnil(L);
                lua_setglobal(L, "LUA_PIPE_LAST");
                lua_pushboolean(L, 0);
                lua_setglobal(L, "LUA_PIPE_ACTIVE");
                return 0;
            }

            if (ref != LUA_NOREF && ref != LUA_REFNIL) {
                luaL_unref(L, LUA_REGISTRYINDEX, ref);
            }
            lua_getglobal(L, "LUA_PIPE_OUT");
            ref = luaL_ref(L, LUA_REGISTRYINDEX);
        }
        if (ref != LUA_NOREF && ref != LUA_REFNIL) {
            luaL_unref(L, LUA_REGISTRYINDEX, ref);
        }
        lua_pushnil(L);
        lua_setglobal(L, "LUA_PIPE_IN");
        lua_pushnil(L);
        lua_setglobal(L, "LUA_PIPE_OUT");
        lua_pushnil(L);
        lua_setglobal(L, "LUA_PIPE_LAST");
        lua_pushboolean(L, 0);
        lua_setglobal(L, "LUA_PIPE_ACTIVE");
        return 1;
    }

    pipefds = calloc((size_t)(2 * (n - 1)), sizeof(int));
    pids = calloc((size_t)n, sizeof(pid_t));
    if (!pipefds || !pids) {
        fprintf(stderr, "Pipeline error: out of memory\n");
        free(pipefds);
        free(pids);
        return 0;
    }

    for (i = 0; i < n - 1; i++) {
        if (pipe(&pipefds[2 * i]) < 0) {
            fprintf(stderr, "Pipeline error: pipe creation failed: %s\n", strerror(errno));
            success = 0;
            break;
        }
    }
    if (!success) {
        for (i = 0; i < n - 1; i++) {
            if (pipefds[2 * i] > 0) {
                close(pipefds[2 * i]);
            }
            if (pipefds[2 * i + 1] > 0) {
                close(pipefds[2 * i + 1]);
            }
        }
        free(pipefds);
        free(pids);
        return 0;
    }

    for (i = 0; i < n; i++) {
        pid_t pid = fork();
        if (pid < 0) {
            fprintf(stderr, "Pipeline error: fork failed: %s\n", strerror(errno));
            success = 0;
            break;
        }
        if (pid == 0) {
            int j;
            char fallback_chunk[1024];

            if (i > 0) {
                dup2(pipefds[2 * (i - 1)], STDIN_FILENO);
            }
            if (i < n - 1) {
                dup2(pipefds[2 * i + 1], STDOUT_FILENO);
            }
            for (j = 0; j < 2 * (n - 1); j++) {
                close(pipefds[j]);
            }

            build_lua_fallback_chunk(&pipeline->commands[i], fallback_chunk, sizeof(fallback_chunk));
            {
                int ok = execute_single_command(L, &pipeline->commands[i], fallback_chunk, 1);
                lua_close(L);
                exit(ok ? 0 : 1);
            }
        }
        pids[i] = pid;
    }

    for (i = 0; i < 2 * (n - 1); i++) {
        close(pipefds[i]);
    }

    if (!success) {
        for (i = 0; i < n; i++) {
            if (pids[i] > 0) {
                waitpid(pids[i], NULL, 0);
            }
        }
        free(pipefds);
        free(pids);
        return 0;
    }

    for (i = 0; i < n; i++) {
        int status;
        if (pids[i] > 0 && waitpid(pids[i], &status, 0) < 0) {
            success = 0;
        }
    }

    free(pipefds);
    free(pids);
    return success;
}

static int is_parent_builtin_name(const char *name) {
    const char *parent_builtins[] = {
        "cd",
        "source",
        "setprompt",
        "alias",
        "preview",
        "history",
        "lunabuffer",
        "tui",
        "jobs",
        "fg",
        "bg",
    };
    int i;
    for (i = 0; i < (int)(sizeof(parent_builtins) / sizeof(parent_builtins[0])); i++) {
        if (strcmp(name, parent_builtins[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static int strip_background_suffix(const char *line, char **out_line, int *is_background) {
    size_t len;
    char *copy;
    size_t end;
    *is_background = 0;
    *out_line = NULL;

    if (!line) {
        return 0;
    }

    len = strlen(line);
    copy = dup_cstr(line);
    if (!copy) {
        return 0;
    }

    end = len;
    while (end > 0 && isspace((unsigned char)copy[end - 1])) {
        end--;
    }
    if (end > 0 && copy[end - 1] == '&') {
        *is_background = 1;
        end--;
        while (end > 0 && isspace((unsigned char)copy[end - 1])) {
            end--;
        }
    }
    copy[end] = '\0';
    *out_line = copy;
    return 1;
}

static int run_job_command(lua_State *L, const CommandAst *ast, const char *line_for_job, int background, int *status_out) {
    pid_t pid;
    int status = 0;
    int stopped = 0;
    int jid;

    *status_out = 0;
    fflush(NULL);
    pid = fork();
    if (pid < 0) {
        fprintf(stderr, "Job launch error: %s\n", strerror(errno));
        *status_out = 1;
        return 0;
    }

    if (pid == 0) {
        setpgid(0, 0);
        reset_child_signals();
        if (ast->pipeline.command_count > 1) {
            int ok = execute_pipeline(L, &ast->pipeline);
            lua_close(L);
            exit(ok ? 0 : 1);
        } else {
            {
                int ok = execute_single_command(L, &ast->pipeline.commands[0], line_for_job, 0);
                lua_close(L);
                exit(ok ? 0 : 1);
            }
        }
    }

    setpgid(pid, pid);

    if (background) {
        jid = add_job(pid, line_for_job, JOB_RUNNING);
        if (jid > 0) {
            printf("[%d] %d\n", jid, (int)pid);
        }
        *status_out = 0;
        return 1;
    }

    if (!wait_foreground_job(pid, &stopped, &status)) {
        fprintf(stderr, "Job wait error: %s\n", strerror(errno));
        *status_out = 1;
        return 0;
    }

    if (stopped) {
        jid = add_job(pid, line_for_job, JOB_STOPPED);
        if (jid > 0) {
            printf("\n[%d] Stopped %s\n", jid, line_for_job ? line_for_job : "");
        }
        *status_out = 148;
    } else {
        *status_out = status;
    }
    return 1;
}

int main() {
    lua_State *L;
    int done = 0;
    int last_status = 0;
    int warned_prompt = 0;
    int warned_prompt_cont = 0;
    const char *last_mode = "lua";
    char parse_err[MAX_PARSE_ERR];
    char cwd[PATH_MAX];

    L = luaL_newstate();
    luaL_openlibs(L);
    using_history();
    g_shell_pgid = getpgrp();
    signal(SIGINT, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
    lua_pushcfunction(L, lua_listdir);
    lua_setglobal(L, "_LISTDIR");
    lua_pushcfunction(L, lua_isdir);
    lua_setglobal(L, "_ISDIR");
    lua_pushcfunction(L, lua_mkdir);
    lua_setglobal(L, "_MKDIR");
    lua_pushcfunction(L, lua_sleep);
    lua_setglobal(L, "_SLEEP");
    lua_pushcfunction(L, lua_getch);
    lua_setglobal(L, "_GETCH");
    lua_pushcfunction(L, lua_resolve_cmd);
    lua_setglobal(L, "_RESOLVE_CMD");
    lua_pushcfunction(L, lua_resolve_path);
    lua_setglobal(L, "_RESOLVE_PATH");
    lua_pushcfunction(L, lua_stat);
    lua_setglobal(L, "_STAT");
    lua_pushcfunction(L, lua_readlink);
    lua_setglobal(L, "_READLINK");
    lua_pushcfunction(L, lua_uid_name);
    lua_setglobal(L, "_UID_NAME");
    lua_pushcfunction(L, lua_gid_name);
    lua_setglobal(L, "_GID_NAME");
    lua_pushcfunction(L, lua_isatty);
    lua_setglobal(L, "_ISATTY");
    lua_pushcfunction(L, lua_lunabuffer_status);
    lua_setglobal(L, "_LUNABUFFER_STATUS");
    lua_pushcfunction(L, lua_lunabuffer_set_size);
    lua_setglobal(L, "_LUNABUFFER_SET_SIZE");
    lua_pushcfunction(L, lua_lunabuffer_clear);
    lua_setglobal(L, "_LUNABUFFER_CLEAR");
    lua_pushcfunction(L, lua_lunabuffer_save);
    lua_setglobal(L, "_LUNABUFFER_SAVE");
    lua_pushcfunction(L, lua_history_list);
    lua_setglobal(L, "_HISTORY_LIST");
    lua_pushcfunction(L, lua_history_clear);
    lua_setglobal(L, "_HISTORY_CLEAR");
    lua_pushcfunction(L, lua_history_read);
    lua_setglobal(L, "_HISTORY_READ");
    lua_pushcfunction(L, lua_history_write);
    lua_setglobal(L, "_HISTORY_WRITE");
    lua_pushcfunction(L, lua_history_path);
    lua_setglobal(L, "_HISTORY_PATH");
    lua_pushcfunction(L, lua_jobs_list);
    lua_setglobal(L, "_JOBS_LIST");
    lua_pushcfunction(L, lua_job_fg);
    lua_setglobal(L, "_JOB_FG");
    lua_pushcfunction(L, lua_job_bg);
    lua_setglobal(L, "_JOB_BG");
    lua_pushcfunction(L, lua_preview_get);
    lua_setglobal(L, "_PREVIEW_GET");
    lua_pushcfunction(L, lua_preview_set);
    lua_setglobal(L, "_PREVIEW_SET");
    lua_pushboolean(L, 0);
    lua_setglobal(L, "PREVIEW_MODE");
    lua_pushboolean(L, 0);
    lua_setglobal(L, "LUA_PIPE_ACTIVE");
    lua_pushnil(L);
    lua_setglobal(L, "LUA_PIPE_IN");
    lua_pushnil(L);
    lua_setglobal(L, "LUA_PIPE_OUT");
    lua_pushnil(L);
    lua_setglobal(L, "LUA_PIPE_LAST");
    lua_pushcfunction(L, lua_alias_fn);
    lua_setglobal(L, "alias");
    lua_pushcfunction(L, lua_pour_fn);
    lua_setglobal(L, "pour");
    lua_newtable(L);
    lua_setglobal(L, "ALIASES");
    lua_newtable(L);
    lua_setglobal(L, "UTIL");

    // Initialize shell working directory from process cwd.
    if (!init_luna_buffers()) {
        fprintf(stderr, "Failed to initialize lunabuffer paths\n");
    }
    if (!init_history_path()) {
        fprintf(stderr, "Failed to initialize history path\n");
    } else {
        read_history(g_history_path);
    }

    if (getcwd(cwd, sizeof(cwd)) != NULL) {
        lua_pushstring(L, cwd);
    } else {
        lua_pushstring(L, ".");
    }
    lua_setglobal(L, "G_CWD");
    maybe_load_user_rc(L);
    
    while (!done) {
        CommandAst ast;
        CommandNode *cmd;
        const char *parse_line;
        const char *history_line;
        char *run_line = NULL;
        int background = 0;
        int force_preview_run = 0;
        int force_preview_exec = 0;
        int bypass_preview_skip = 0;
        ParseSyntaxMode parse_mode = SYNTAX_LUNA;
        int exec_ok = 1;
        char history_err[MAX_PARSE_ERR];
        char *history_expanded = NULL;

        if (is_tui_mode_enabled(L)) {
            render_tui(L);
        } else {
            g_tui_initialized = 0;
        }
        update_prompt_context(L, last_status, last_mode);
        char *line = read_repl_input(L, &warned_prompt, &warned_prompt_cont);

        if (!line) {
            done = 1;
            continue;
        }

        parse_line = line;
        while (*parse_line && isspace((unsigned char)*parse_line)) {
            parse_line++;
        }
        history_line = parse_line;

        {
            int exp = expand_history_event(parse_line, &history_expanded, history_err, sizeof(history_err));
            if (exp < 0) {
                fprintf(stderr, "%s\n", history_err);
                free(line);
                continue;
            }
            if (exp > 0 && history_expanded) {
                printf("%s\n", history_expanded);
                parse_line = history_expanded;
                history_line = history_expanded;
            }
        }

        if (*history_line) {
            add_history(history_line);
        }

        if (starts_with(parse_line, ":!")) {
            parse_mode = SYNTAX_LEGACY;
            parse_line += 2;
            last_mode = "legacy";
            while (*parse_line && isspace((unsigned char)*parse_line)) {
                parse_line++;
            }
        } else {
            last_mode = "lua";
        }

        sync_preview_mode_from_lua(L);

        if (starts_with(parse_line, "preview run")
            && (parse_line[11] == '\0' || isspace((unsigned char)parse_line[11]))) {
            force_preview_run = 1;
            parse_line += 11;
            while (*parse_line && isspace((unsigned char)*parse_line)) {
                parse_line++;
            }
            if (*parse_line == '\0') {
                fprintf(stderr, "preview: usage: preview run <command...>\n");
                free(history_expanded);
                free(line);
                continue;
            }
        }

        if (starts_with(parse_line, "preview exec")
            && (parse_line[12] == '\0' || isspace((unsigned char)parse_line[12]))) {
            force_preview_exec = 1;
            parse_line += 12;
            while (*parse_line && isspace((unsigned char)*parse_line)) {
                parse_line++;
            }
            if (*parse_line == '\0') {
                fprintf(stderr, "preview: usage: preview exec <command...>\n");
                free(history_expanded);
                free(line);
                continue;
            }
        }

        if (!strip_background_suffix(parse_line, &run_line, &background)) {
            fprintf(stderr, "Parse error: out of memory\n");
            free(history_expanded);
            free(line);
            continue;
        }
        parse_line = run_line;

        poll_jobs();

        if (!parse_to_ast(parse_line, parse_mode, &ast, parse_err, sizeof(parse_err))) {
            if (parse_mode == SYNTAX_LUNA && starts_with(parse_err, "legacy operator")
                && line_looks_like_lua_chunk(L, parse_line)) {
                lua_pushstring(L, "lua-fallback");
                lua_setglobal(L, "CMD_SOURCE");
                lua_pushnil(L);
                lua_setglobal(L, "CMD_PATH");
                if (!background) {
                    last_status = execute_raw_lua_chunk(L, parse_line) ? 0 : 1;
                } else {
                    pid_t pid = fork();
                    if (pid < 0) {
                        fprintf(stderr, "Job launch error: %s\n", strerror(errno));
                        last_status = 1;
                    } else if (pid == 0) {
                        int ok;
                        setpgid(0, 0);
                        reset_child_signals();
                        ok = execute_raw_lua_chunk(L, parse_line);
                        lua_close(L);
                        exit(ok ? 0 : 1);
                    } else {
                        int jid;
                        setpgid(pid, pid);
                        jid = add_job(pid, parse_line, JOB_RUNNING);
                        if (jid > 0) {
                            printf("[%d] %d\n", jid, (int)pid);
                        }
                        last_status = 0;
                    }
                }
                free(run_line);
                free(history_expanded);
                free(line);
                continue;
            }
            fprintf(stderr, "Parse error: %s\n", parse_err);
            free(run_line);
            free(history_expanded);
            free(line);
            continue;
        }

        if (ast.pipeline.command_count == 0) {
            free_command_ast(&ast);
            free(run_line);
            free(history_expanded);
            free(line);
            continue;
        }

        cmd = &ast.pipeline.commands[0];

        if ((strcmp("quit", cmd->argv[0]) == 0) || (strcmp("exit", cmd->argv[0]) == 0)) {
            done = 1;
            free_command_ast(&ast);
            free(run_line);
            free(history_expanded);
            free(line);
            continue;
        }

        sync_preview_mode_from_lua(L);
        if (force_preview_run) {
            print_preview_plan(L, &ast, parse_line, background, "skipped");
            free_command_ast(&ast);
            free(run_line);
            free(history_expanded);
            free(line);
            continue;
        }
        if (force_preview_exec) {
            print_preview_plan(L, &ast, parse_line, background, "awaiting confirmation");
            if (!confirm_preview_exec()) {
                printf("[preview] execution canceled\n");
                free_command_ast(&ast);
                free(run_line);
                free(history_expanded);
                free(line);
                continue;
            }
            printf("[preview] execution confirmed\n");
            bypass_preview_skip = 1;
        }
        if (g_preview_mode && !(ast.pipeline.command_count == 1 && strcmp(cmd->argv[0], "preview") == 0)
            && !bypass_preview_skip) {
            print_preview_plan(L, &ast, parse_line, background, "skipped");
            free_command_ast(&ast);
            free(run_line);
            free(history_expanded);
            free(line);
            continue;
        }

        if (!background && ast.pipeline.command_count == 1) {
            int run_in_parent = 0;
            char builtin_path[PATH_MAX];
            int is_user_builtin = 0;
            if (is_parent_builtin_name(cmd->argv[0])) {
                run_in_parent = 1;
            } else if (!resolve_builtin_path_for_name(
                           cmd->argv[0], builtin_path, sizeof(builtin_path), &is_user_builtin)) {
                /* Keep Lua-first stateful semantics for fallback Lua chunks. */
                run_in_parent = 1;
            }
            if (run_in_parent) {
                exec_ok = execute_single_command(L, cmd, parse_line, 0);
            } else {
                int child_status = 0;
                exec_ok = run_job_command(L, &ast, parse_line, background, &child_status);
                if (exec_ok) {
                    exec_ok = (child_status == 0);
                }
            }
        } else {
            int child_status = 0;
            exec_ok = run_job_command(L, &ast, parse_line, background, &child_status);
            if (exec_ok) {
                if (background) {
                    child_status = 0;
                }
                exec_ok = (child_status == 0);
            }
        }
        last_status = exec_ok ? 0 : 1;
        free_command_ast(&ast);
        free(run_line);
        free(history_expanded);
        free(line);
    }
    if (g_history_path_ready) {
        write_history(g_history_path);
    }
    lua_close(L);

    return 0;
}
