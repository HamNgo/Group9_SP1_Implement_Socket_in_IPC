# Makefile - chỉ cần gõ 'make' là ra bin/server (và bin/client khi đã có src/client.c)
#
# Dùng wildcard nên file của thành viên 2 và 3 (client.c, utils.c) chưa có thì
# vẫn build được phần đã có; có rồi thì tự được ghép vào, không phải sửa Makefile.

CC      := gcc
CFLAGS  := -std=gnu11 -Wall -Wextra -O2 -g -Iinclude -pthread
LDFLAGS := -pthread

BIN := bin
OBJ := obj

UTILS_SRC  := $(wildcard src/utils.c)
SERVER_OBJ := $(OBJ)/server.o $(patsubst src/%.c,$(OBJ)/%.o,$(UTILS_SRC))
CLIENT_OBJ := $(patsubst src/%.c,$(OBJ)/%.o,$(wildcard src/client.c)) \
              $(patsubst src/%.c,$(OBJ)/%.o,$(UTILS_SRC))

TARGETS := $(BIN)/server $(if $(wildcard src/client.c),$(BIN)/client)

all: $(TARGETS)

$(BIN)/server: $(SERVER_OBJ) | $(BIN)
	$(CC) $(LDFLAGS) -o $@ $^

$(BIN)/client: $(CLIENT_OBJ) | $(BIN)
	$(CC) $(LDFLAGS) -o $@ $^

# Sửa bất kỳ file .h nào thì build lại các file .o
$(OBJ)/%.o: src/%.c $(wildcard include/*.h) | $(OBJ)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BIN) $(OBJ):
	mkdir -p $@

# make demo: chạy lần lượt 3 kịch bản (khi thành viên 3 đã có script)
demo: all
	./scripts/demo_single.sh
	./scripts/demo_multi_client.sh
	./scripts/demo_signal.sh

clean:
	rm -rf $(BIN) $(OBJ)

.PHONY: all demo clean
