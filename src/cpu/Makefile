# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
CC      ?= gcc
CFLAGS  ?= -O3 -march=native -flto -Wall -Wextra -Wno-unused-parameter -Wno-unused-function
LDFLAGS ?= -flto
LDLIBS  := -lgmp -lpthread -lm

KT_DIR    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT      := $(KT_DIR)../..
COMMON    := $(ROOT)/src/common

SRC := kt_gmp_v1.c $(COMMON)/ktuplet_pattern.c $(COMMON)/kt_verify.c
OBJ := $(SRC:.c=.o)

TARGET := kt_search

.PHONY: all clean test smoke

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -I$(COMMON) $(SRC) -o $@ $(LDFLAGS) $(LDLIBS)

test: $(TARGET)
	./$(TARGET) --test

smoke: $(TARGET)
	./$(TARGET) --smoke --pattern KT22_P0 --bits 60 --max-batches 1
	./$(TARGET) --smoke --pattern KT23_P0 --bits 60 --max-batches 1
	./$(TARGET) --smoke --pattern KT24_P0 --bits 60 --max-batches 1

clean:
	rm -f $(TARGET) *.o
