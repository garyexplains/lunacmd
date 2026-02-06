CC := gcc
CFLAGS := -Wall -Wextra -std=c11 -g -Ilua/src
LDFLAGS := -Llua/src
LDLIBS := -llua -lm -lreadline

TARGET := lunacmd
SRC := main.c
LUA_LIB := lua/src/liblua.a

.PHONY: all clean lua test

all: $(TARGET)

$(TARGET): $(SRC) $(LUA_LIB)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS) $(LDLIBS)

$(LUA_LIB):
	$(MAKE) -C lua/src liblua.a

lua: $(LUA_LIB)

test: $(TARGET)
	./tests/sanity.sh

clean:
	rm -f $(TARGET)
	$(MAKE) -C lua/src clean
