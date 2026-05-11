CC := gcc
CFLAGS := -Wall -Wextra -std=c11 -g -Ilua/src
LDFLAGS := -Llua/src
LDLIBS := -llua -lm -lreadline

TARGET := lunacmd
SRC := main.c
LUA_LIB := lua/src/liblua.a
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SHAREDIR ?= $(PREFIX)/share/lunacmd
BUILTINDIR ?= $(SHAREDIR)/builtin
DESTDIR ?=

.PHONY: all clean lua test install uninstall

all: $(TARGET)

$(TARGET): $(SRC) $(LUA_LIB)
	$(CC) $(CFLAGS) -DDEFAULT_BUILTIN_DIR=\"$(BUILTINDIR)\" -o $@ $(SRC) $(LDFLAGS) $(LDLIBS)

$(LUA_LIB):
	$(MAKE) -C lua/src liblua.a

lua: $(LUA_LIB)

test: $(TARGET)
	./tests/sanity.sh

install: $(TARGET)
	install -d "$(DESTDIR)$(BINDIR)"
	install -d "$(DESTDIR)$(BUILTINDIR)"
	install -m 0755 "$(TARGET)" "$(DESTDIR)$(BINDIR)/$(TARGET)"
	install -m 0644 builtin/*.lua "$(DESTDIR)$(BUILTINDIR)/"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(TARGET)"
	rm -rf "$(DESTDIR)$(SHAREDIR)"

clean:
	rm -f $(TARGET)
	$(MAKE) -C lua/src clean
