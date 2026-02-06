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
#include <readline/history.h>
#include <readline/readline.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* A static variable for holding the line. */
static char *line_read = (char *)NULL;

#define MAX_CMD_TOKENS 64

typedef struct ParsedCommand {
    int argc;
    char *argv[MAX_CMD_TOKENS];
} ParsedCommand;

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
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

static void free_parsed_command(ParsedCommand *cmd) {
    int i;
    for (i = 0; i < cmd->argc; i++) {
        free(cmd->argv[i]);
        cmd->argv[i] = NULL;
    }
    cmd->argc = 0;
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

static int parse_command_line(const char *line, ParsedCommand *out, char *err, size_t err_size) {
    const char *p = line;
    out->argc = 0;

    while (*p) {
        char *token = NULL;
        size_t token_len = 0;
        size_t token_capacity = 0;
        int in_single = 0;
        int in_double = 0;

        while (*p && isspace((unsigned char)*p)) {
            p++;
        }

        if (!*p) {
            break;
        }

        if (out->argc >= MAX_CMD_TOKENS) {
            snprintf(err, err_size, "too many arguments (max %d)", MAX_CMD_TOKENS - 1);
            free_parsed_command(out);
            return 0;
        }

        while (*p) {
            if (!in_single && !in_double && isspace((unsigned char)*p)) {
                break;
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
                    if (!append_char(&token, &token_len, &token_capacity, '\\')) {
                        snprintf(err, err_size, "out of memory");
                        free(token);
                        free_parsed_command(out);
                        return 0;
                    }
                    break;
                }
            }

            if (!append_char(&token, &token_len, &token_capacity, *p)) {
                snprintf(err, err_size, "out of memory");
                free(token);
                free_parsed_command(out);
                return 0;
            }
            p++;
        }

        if (in_single || in_double) {
            snprintf(err, err_size, "unterminated quote");
            free(token);
            free_parsed_command(out);
            return 0;
        }

        if (!append_char(&token, &token_len, &token_capacity, '\0')) {
            snprintf(err, err_size, "out of memory");
            free(token);
            free_parsed_command(out);
            return 0;
        }

        out->argv[out->argc] = token;
        out->argc++;
    }

    return 1;
}

static void set_lua_command_globals(lua_State *L, const ParsedCommand *cmd) {
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

static char *read_repl_input() {
    char *combined = NULL;
    size_t combined_len = 0;
    size_t combined_cap = 0;
    int first_line = 1;

    while (1) {
        size_t content_len;
        int continued;
        char *segment = rl_gets(first_line ? "" : "... ", 0);

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

int main() {
    int status, result;
    lua_State *L;
    int done = 0;
    char builtincmdbuff[256];
    ParsedCommand cmd;
    char parse_err[128];
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

    // Initialize shell working directory from process cwd.
    if (getcwd(cwd, sizeof(cwd)) != NULL) {
        lua_pushstring(L, cwd);
    } else {
        lua_pushstring(L, ".");
    }
    lua_setglobal(L, "G_CWD");
    
    while (!done) {
        char *line = read_repl_input();

        if (!line) {
            done = 1;
            continue;
        }

        if (!parse_command_line(line, &cmd, parse_err, sizeof(parse_err))) {
            fprintf(stderr, "Parse error: %s\n", parse_err);
            free(line);
            continue;
        }

        if (cmd.argc == 0) {
            free_parsed_command(&cmd);
            free(line);
            continue;
        }

        if ((strcmp("quit", cmd.argv[0]) == 0) || (strcmp("exit", cmd.argv[0]) == 0)) {
            done = 1;
            free_parsed_command(&cmd);
            free(line);
            continue;
        }

        set_lua_command_globals(L, &cmd);

        if (snprintf(builtincmdbuff, sizeof(builtincmdbuff), "builtin/%s.lua", cmd.argv[0]) >=
            (int)sizeof(builtincmdbuff)) {
            fprintf(stderr, "Command name is too long\n");
            free_parsed_command(&cmd);
            free(line);
            continue;
        }

        status = luaL_loadfile(L, builtincmdbuff);
        if (!status) {
            result = lua_pcall(L, 0, LUA_MULTRET, 0);
            if (result) {
                fprintf(stderr, "Failed to run script: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            const char *load_err = lua_tostring(L, -1);
            int missing_builtin =
                load_err && (starts_with(load_err, "cannot open ") ||
                             strstr(load_err, "No such file or directory") != NULL);

            lua_pop(L, 1);

            if (missing_builtin) {
                // No built-in Lua script; evaluate as Lua code.
                if (luaL_dostring(L, line) != LUA_OK) {
                    fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                fprintf(stderr, "Failed to load builtin '%s': %s\n",
                        cmd.argv[0],
                        load_err ? load_err : "unknown error");
            }
        }
        free_parsed_command(&cmd);
        free(line);
    }
    lua_close(L);

    return 0;
}
