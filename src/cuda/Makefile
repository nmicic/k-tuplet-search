# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# kt_filter Makefile — two production engines:
#   kt_filter_v5  (oracle / CPU-era GPU port, streams + Barrett mod)
#   kt_filter_v8  (main search engine, wheel-offset 2-D launch + multi-module)
#
# Build from src/cuda/:
#   make kt_filter_v8          # production binary
#   make kt_filter_v5          # oracle binary
#   make test                  # build v8 + run --test + external smokes
#   make clean

NVCC      ?= /usr/local/cuda-13.2/bin/nvcc
NVCC_ARCH ?= sm_120
CC        ?= cc
GP        ?= gp

# Auto-detect ktuplet_pattern.{c,h} location: prefer the current dir
# (remote build, files copied flat) so the most recent scp wins; fall back
# to ../common (in-repo dev).
COMMON_DIR := $(if $(wildcard ./ktuplet_pattern.h),.,../common)

# Build SHA injected into binaries so novel_records.jsonl entries are
# traceable. Falls back to "unknown" outside a git checkout.
# `?=` so an env override (KT_BUILD_SHA=feedface make ...) wins.
KT_BUILD_SHA ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

NVCCFLAGS := -O3 -std=c++17 -lineinfo -arch=$(NVCC_ARCH) -I$(COMMON_DIR) -I. \
             -DKT_BUILD_SHA=\"$(KT_BUILD_SHA)\"
# Set NVCC_FLAGS_EXTRA on the command line for sweeps:
#   make kt_filter_v8 NVCC_FLAGS_EXTRA="-Xptxas -v -maxrregcount=48 -DKT_LB_BLOCKS=6"
NVCC_FLAGS_EXTRA ?=
CFLAGS    := -O3 -std=c11 -Wall -Wextra -I$(COMMON_DIR) -I.

LDLIBS    := -lgmp

# Production engine sources
TARGET_V5 := kt_filter_v5
CU_SRC_V5 := kt_filter_v5.cu
TARGET_V8 := kt_filter_v8
CU_SRC_V8 := kt_filter_v8.cu

# Shared object modules
PAT_SRC   := $(COMMON_DIR)/ktuplet_pattern.c
PAT_OBJ   := ktuplet_pattern.o
WHEEL_SRC := kt_wheel.c
WHEEL_HDR := kt_wheel.h
WHEEL_OBJ := kt_wheel.o

# v8 module decomposition (extracted from kt_filter_v8.cu)
LANES_SRC := kt_lanes.c
LANES_HDR := kt_lanes.h
LANES_OBJ := kt_lanes.o
CKPT_SRC  := kt_checkpoint.c
CKPT_HDR  := kt_checkpoint.h
CKPT_OBJ  := kt_checkpoint.o
NOVEL_SRC := kt_novel_record.c
NOVEL_HDR := kt_novel_record.h
NOVEL_OBJ := kt_novel_record.o
RECORDS_SRC := kt_records.c
RECORDS_HDR := kt_records.h
RECORDS_OBJ := kt_records.o
CLI_SRC := kt_cli.c
CLI_HDR := kt_cli.h
CLI_OBJ := kt_cli.o
SIGNAL_SRC := kt_signal.cu
SIGNAL_HDR := kt_signal.h
SIGNAL_OBJ := kt_signal.o
REPORTER_SRC := kt_reporter.cu
REPORTER_HDR := kt_reporter.h
REPORTER_OBJ := kt_reporter.o
TESTS_SRC := kt_tests.cu
TESTS_HDR := kt_tests.h
TESTS_OBJ := kt_tests.o

VERIFY_SRC := $(COMMON_DIR)/kt_verify.c
VERIFY_HDR := $(COMMON_DIR)/kt_verify.h
VERIFY_OBJ := kt_verify.o
JSON_SRC  := $(COMMON_DIR)/kt_json_min.c
JSON_HDR  := $(COMMON_DIR)/kt_json_min.h
JSON_OBJ  := kt_json_min.o

# kt_filter_v8.cu includes this baked-mask header for the F1 bit-identity
# validator (--enable-f1-validator, default OFF).
F1_BAKED_HDR := kt_filter_v5_f1_baked.h

# Baseline compile flags for v8 (hard-coded so `make kt_filter_v8` without
# env produces the correct 40-register / 6-block launch-bounds binary).
# An explicit NVCC_FLAGS_EXTRA env var appends after these.
KT_V8_BASELINE_FLAGS := -Xptxas -v -maxrregcount=48 -DKT_LB_BLOCKS=6

.PHONY: all clean check-syntax canonical-hashes test test-features kt_filter_v5 kt_filter_v8

all: $(TARGET_V8)

$(PAT_OBJ): $(PAT_SRC) $(COMMON_DIR)/ktuplet_pattern.h
	$(CC) $(CFLAGS) -c $(PAT_SRC) -o $(PAT_OBJ)

$(WHEEL_OBJ): $(WHEEL_SRC) $(WHEEL_HDR)
	$(CC) $(CFLAGS) -c $(WHEEL_SRC) -o $(WHEEL_OBJ)

$(LANES_OBJ): $(LANES_SRC) $(LANES_HDR)
	$(CC) $(CFLAGS) -c $(LANES_SRC) -o $(LANES_OBJ)

$(CKPT_OBJ): $(CKPT_SRC) $(CKPT_HDR)
	$(CC) $(CFLAGS) -c $(CKPT_SRC) -o $(CKPT_OBJ)

$(NOVEL_OBJ): $(NOVEL_SRC) $(NOVEL_HDR)
	$(CC) $(CFLAGS) -c $(NOVEL_SRC) -o $(NOVEL_OBJ)

$(RECORDS_OBJ): $(RECORDS_SRC) $(RECORDS_HDR) $(JSON_HDR)
	$(CC) $(CFLAGS) -c $(RECORDS_SRC) -o $(RECORDS_OBJ)

$(CLI_OBJ): $(CLI_SRC) $(CLI_HDR)
	$(CC) $(CFLAGS) -DKT_BUILD_SHA=\"$(KT_BUILD_SHA)\" -c $(CLI_SRC) -o $(CLI_OBJ)

$(SIGNAL_OBJ): $(SIGNAL_SRC) $(SIGNAL_HDR)
	$(NVCC) $(NVCCFLAGS) -c $(SIGNAL_SRC) -o $(SIGNAL_OBJ)

$(REPORTER_OBJ): $(REPORTER_SRC) $(REPORTER_HDR) $(SIGNAL_HDR) $(CLI_HDR)
	$(NVCC) $(NVCCFLAGS) -c $(REPORTER_SRC) -o $(REPORTER_OBJ)

$(TESTS_OBJ): $(TESTS_SRC) $(TESTS_HDR) $(SIGNAL_HDR) $(CLI_HDR) $(LANES_HDR) $(NOVEL_HDR) $(RECORDS_HDR)
	$(NVCC) $(NVCCFLAGS) $(KT_V8_BASELINE_FLAGS) -c $(TESTS_SRC) -o $(TESTS_OBJ)

$(VERIFY_OBJ): $(VERIFY_SRC) $(VERIFY_HDR) $(COMMON_DIR)/ktuplet_pattern.h
	$(CC) $(CFLAGS) -c $(VERIFY_SRC) -o $(VERIFY_OBJ)

$(JSON_OBJ): $(JSON_SRC) $(JSON_HDR)
	$(CC) $(CFLAGS) -c $(JSON_SRC) -o $(JSON_OBJ)

# kt_filter_v5: oracle engine (streams + Barrett mod, single-module build).
$(TARGET_V5): NVCC_FLAGS_EXTRA ?= -Xptxas -v -maxrregcount=48 -DKT_LB_BLOCKS=6
$(TARGET_V5): $(CU_SRC_V5) $(PAT_OBJ) $(WHEEL_OBJ) $(WHEEL_HDR) $(VERIFY_OBJ) $(JSON_OBJ)
	$(NVCC) $(NVCCFLAGS) $(NVCC_FLAGS_EXTRA) $(CU_SRC_V5) $(PAT_OBJ) $(WHEEL_OBJ) $(VERIFY_OBJ) $(JSON_OBJ) $(LDLIBS) -o $(TARGET_V5)

# kt_filter_v8: main search engine (wheel-offset 2-D launch, multi-module).
$(TARGET_V8): $(CU_SRC_V8) $(F1_BAKED_HDR) $(PAT_OBJ) $(WHEEL_OBJ) $(WHEEL_HDR) $(VERIFY_OBJ) $(JSON_OBJ) $(LANES_OBJ) $(LANES_HDR) $(CKPT_OBJ) $(CKPT_HDR) $(NOVEL_OBJ) $(NOVEL_HDR) $(RECORDS_OBJ) $(RECORDS_HDR) $(CLI_OBJ) $(CLI_HDR) $(SIGNAL_OBJ) $(SIGNAL_HDR) $(REPORTER_OBJ) $(REPORTER_HDR) $(TESTS_OBJ) $(TESTS_HDR)
	$(NVCC) $(NVCCFLAGS) $(KT_V8_BASELINE_FLAGS) $(NVCC_FLAGS_EXTRA) $(CU_SRC_V8) $(PAT_OBJ) $(WHEEL_OBJ) $(VERIFY_OBJ) $(JSON_OBJ) $(LANES_OBJ) $(CKPT_OBJ) $(NOVEL_OBJ) $(RECORDS_OBJ) $(CLI_OBJ) $(SIGNAL_OBJ) $(REPORTER_OBJ) $(TESTS_OBJ) $(LDLIBS) -o $(TARGET_V8)

check-syntax:
	@echo "check-syntax: nvcc-only build; no local stub yet (nvcc required)"

# Run embedded unit tests + external feature smokes.
test: $(TARGET_V8) test-features
	./$(TARGET_V8) --test

# Stand-alone target: run only the external smokes (assumes binary already built).
test-features: $(TARGET_V8)
	KT_BIN=$(abspath $(TARGET_V8)) bash ../../tests/test_features_actually_run.sh

# Regenerate the canonical-hash table pasted into kt_wheel.c (manual one-shot).
canonical-hashes:
	$(GP) -q -f --default parisizemax=4G --default parisize=512M ../../tools/dump_wheel_canonical_hash.gp

clean:
	rm -f $(TARGET_V5) $(TARGET_V8) \
	      $(PAT_OBJ) $(WHEEL_OBJ) $(VERIFY_OBJ) $(JSON_OBJ) \
	      $(LANES_OBJ) $(CKPT_OBJ) $(NOVEL_OBJ) $(RECORDS_OBJ) \
	      $(CLI_OBJ) $(SIGNAL_OBJ) $(REPORTER_OBJ) $(TESTS_OBJ) *.o
