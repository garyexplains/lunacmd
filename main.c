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
#include <readline/history.h>
#include <readline/readline.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* A static variable for holding the line. */
static char *line_read = (char *)NULL;

#define MAX_PARSE_ERR 256

typedef enum TokenType {
    TOKEN_EOF = 0,
    TOKEN_WORD,
    TOKEN_PIPE,
    TOKEN_REDIR_IN,
    TOKEN_REDIR_OUT,
    TOKEN_REDIR_OUT_APPEND,
    TOKEN_REDIR_ERR_OUT,
    TOKEN_REDIR_ERR_OUT_APPEND,
    TOKEN_REDIR_ERR_TO_OUT,
} TokenType;

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
} PipelineNode;

typedef struct CommandAst {
    PipelineNode pipeline;
} CommandAst;

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int is_env_enabled(const char *name) {
    const char *v = getenv(name);
    return v && *v;
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

static int resolve_builtin_path_for_name(
    const char *cmd, char *out_path, size_t out_size, int *is_user_builtin) {
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
        if ((strcmp(entry->d_name, ".") == 0) || (strcmp(entry->d_name, "..") == 0)) {
            continue;
        }
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

        while (tok.type != TOKEN_EOF && tok.type != TOKEN_PIPE) {
            if (tok.type == TOKEN_WORD) {
                if (mode == SYNTAX_LUNA && is_legacy_operator_word(tok.text)) {
                    snprintf(err,
                             err_size,
                             "legacy operator '%s' requires ':!' prefix (or use lunacmd operators like :>, :<, :|)",
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
            L, first_line ? "PROMPT" : "PROMPT_CONT", first_line ? "" : "... ", first_line
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
                if (*combined) {
                    add_history(combined);
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
        if (*combined) {
            add_history(combined);
        }
        return combined;
    }
}

typedef struct FdSnapshot {
    int saved_stdin;
    int saved_stdout;
    int saved_stderr;
} FdSnapshot;

static void init_fd_snapshot(FdSnapshot *snap) {
    snap->saved_stdin = -1;
    snap->saved_stdout = -1;
    snap->saved_stderr = -1;
}

static int ensure_saved_fd(int target_fd, int *slot) {
    if (*slot >= 0) {
        return 1;
    }
    *slot = dup(target_fd);
    return *slot >= 0;
}

static int resolve_redirection_path(lua_State *L, const char *target, char *out, size_t out_size) {
    const char *cwd = ".";

    if (!target || !*target) {
        return 0;
    }
    if (target[0] == '/') {
        return snprintf(out, out_size, "%s", target) < (int)out_size;
    }

    lua_getglobal(L, "G_CWD");
    if (lua_isstring(L, -1)) {
        cwd = lua_tostring(L, -1);
    }
    if (!cwd || !*cwd) {
        cwd = ".";
    }
    lua_pop(L, 1);

    return snprintf(out, out_size, "%s/%s", cwd, target) < (int)out_size;
}

static int apply_redirections(
    lua_State *L, const CommandNode *cmd, FdSnapshot *snap, char *err, size_t err_size) {
    int i;
    for (i = 0; i < cmd->redir_count; i++) {
        int fd = -1;
        int flags = 0;
        int target_fd = -1;
        char path[PATH_MAX];
        Redirection *r = &cmd->redirs[i];

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

        if (!resolve_redirection_path(L, r->target, path, sizeof(path))) {
            snprintf(err, err_size, "redirection path too long");
            return 0;
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
    int has_builtin = 0;
    int is_user_builtin = 0;
    char builtin_path[PATH_MAX];
    char fallback_chunk[1024];
    FdSnapshot snap;
    char redir_err[MAX_PARSE_ERR];

    set_lua_command_globals(L, cmd);
    has_builtin = resolve_builtin_path_for_name(
        cmd->argv[0], builtin_path, sizeof(builtin_path), &is_user_builtin);

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
    if (!apply_redirections(L, cmd, &snap, redir_err, sizeof(redir_err))) {
        fprintf(stderr, "Redirection error: %s\n", redir_err);
        restore_redirections(&snap);
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
        return 1;
    } else {
        if (!has_builtin) {
            const char *chunk = original_line;
            if (force_reconstructed_chunk || cmd->redir_count > 0) {
                build_lua_fallback_chunk(cmd, fallback_chunk, sizeof(fallback_chunk));
                chunk = fallback_chunk;
            }

            if (luaL_dostring(L, chunk) != LUA_OK) {
                fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            const char *load_err = lua_tostring(L, -1);
            fprintf(stderr,
                    "Failed to load builtin '%s': %s\n",
                    cmd->argv[0],
                    load_err ? load_err : "unknown error");
            lua_pop(L, 1);
        }
        restore_redirections(&snap);
        return 1;
    }
}

static int execute_pipeline(lua_State *L, const PipelineNode *pipeline) {
    int i;
    int n = pipeline->command_count;
    int *pipefds = NULL;
    pid_t *pids = NULL;
    int success = 1;

    if (n <= 0) {
        return 1;
    }
    if (n == 1) {
        return execute_single_command(L, &pipeline->commands[0], NULL, 1);
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
            execute_single_command(L, &pipeline->commands[i], fallback_chunk, 1);
            _exit(0);
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
    lua_pushcfunction(L, lua_listdir);
    lua_setglobal(L, "_LISTDIR");
    lua_pushcfunction(L, lua_isdir);
    lua_setglobal(L, "_ISDIR");
    lua_pushcfunction(L, lua_mkdir);
    lua_setglobal(L, "_MKDIR");
    lua_pushcfunction(L, lua_sleep);
    lua_setglobal(L, "_SLEEP");
    lua_pushcfunction(L, lua_resolve_cmd);
    lua_setglobal(L, "_RESOLVE_CMD");

    // Initialize shell working directory from process cwd.
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
        ParseSyntaxMode parse_mode = SYNTAX_LUNA;
        int exec_ok = 1;

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

        if (!parse_to_ast(parse_line, parse_mode, &ast, parse_err, sizeof(parse_err))) {
            fprintf(stderr, "Parse error: %s\n", parse_err);
            free(line);
            continue;
        }

        if (ast.pipeline.command_count == 0) {
            free_command_ast(&ast);
            free(line);
            continue;
        }

        cmd = &ast.pipeline.commands[0];

        if ((strcmp("quit", cmd->argv[0]) == 0) || (strcmp("exit", cmd->argv[0]) == 0)) {
            done = 1;
            free_command_ast(&ast);
            free(line);
            continue;
        }

        if (ast.pipeline.command_count > 1) {
            exec_ok = execute_pipeline(L, &ast.pipeline);
        } else {
            exec_ok = execute_single_command(L, cmd, parse_line, 0);
        }
        last_status = exec_ok ? 0 : 1;
        free_command_ast(&ast);
        free(line);
    }
    lua_close(L);

    return 0;
}
