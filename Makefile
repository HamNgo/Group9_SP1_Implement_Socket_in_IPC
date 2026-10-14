
cat << 'EOF' > Makefile


# Makefile - Topic 25: Sockets in IPC
# Course: SP(1).en2026 - Group 9 VKU
# Author: Vo Thanh Long - 23IT147

CC = gcc
CFLAGS = -Wall -Wextra -pthread -I./common

all:
	@echo "=========================================================="
	@echo "SP(1).en2026 - Group 9 VKU | Leader: Vo Thanh Long 23IT147"
	@echo "Building Topic 25: Multi-threaded Sockets in IPC..."
	@echo "=========================================================="
	@echo "Status: Protocol and workspace initialized for 4 members."

clean:
	rm -f /tmp/ipc_group9_*.sock
	rm -f output.txt
	@echo "Cleaned up temporary socket files and logs."

.PHONY: all clean
