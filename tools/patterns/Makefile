# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# Build pattern_enum (C port of enumerate_patterns.py).
#
#   make            - build pattern_enum
#   make test       - build + run self-tests (14/14 expected)
#   make clean      - remove binary

CC      ?= gcc
CFLAGS  ?= -O3 -fopenmp -Wall -Wextra
LDFLAGS ?= -fopenmp

TARGET = pattern_enum
SRC = pattern_enum.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: $(TARGET)
	./$(TARGET) --self-test

clean:
	rm -f $(TARGET)

.PHONY: all test clean
