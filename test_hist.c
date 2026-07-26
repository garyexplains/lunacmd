#include <stdio.h>
#include <readline/history.h>
int main() {
    int r = read_history("test_history");
    add_history("new_entry");
    printf("history_length = %d, history_base = %d\n", history_length, history_base);
    for (int i = 0; i < history_length; i++) {
        HIST_ENTRY *e = history_get(history_base + i);
        if (e) printf("entry %d: %s\n", i, e->line);
    }
    return 0;
}
