/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_u128.cu — placeholder TU for the u128 GPU primitives.
 *
 * All __device__ helpers live in kt_u128.h as static inline so the kernel TU
 * inlines them without relocatable-device-code linking. This file exists so
 * the build manifest has a stable per-symbol object for out-of-tree consumers
 * if they ever need one.
 */

#include "kt_u128.h"
