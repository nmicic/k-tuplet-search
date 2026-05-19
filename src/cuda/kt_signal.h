/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_signal.h — signal + atexit + fatal-cleanup surface, extracted from
 * kt_filter_v8.cu in W20-DEC Phase 3 Step 6.
 *
 * Approach 1 (brief): the three engine globals these paths touch
 * (g_log_fp, g_shutdown_requested, s_w19b_counter_stream) stay DEFINED
 * in core where the engine hot-path consumes them, and are declared
 * `extern` here so kt_signal.cu can read/write them.
 *
 * This header is consumed both by kt_signal.cu (defines) and by
 * kt_filter_v8.cu (registers atexit handlers, calls kt_fatal_cleanup
 * from W18-A alignment + W19-A W18-K trip-wire paths).
 */
#ifndef KT_SIGNAL_H
#define KT_SIGNAL_H

#include <stdio.h>           /* FILE * for g_log_fp */
#include <signal.h>          /* sig_atomic_t */
#include <cuda_runtime.h>    /* cudaStream_t for s_w19b_counter_stream */

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Engine globals consumed by the signal/atexit/fatal paths ---- */

/* Survivor log FILE *.  final_log_flush() fflush+fsyncs this at clean exit. */
extern FILE *g_log_fp;

/* Set by signal_handler() (SIGINT/SIGTERM/SIGHUP) and polled by the engine
 * loop to trigger graceful drain.  Async-signal-safe: only assigning to a
 * volatile sig_atomic_t is POSIX-guaranteed from a signal handler. */
extern volatile sig_atomic_t g_shutdown_requested;

/* W19-B-5 counter-read stream; kt_cuda_cleanup_atexit destroys it if
 * run_search_loop's own teardown was skipped (SIGINT mid-loop, etc.). */
extern cudaStream_t s_w19b_counter_stream;

/* ---- atexit-registered handlers ---- */

/* Flush + fsync g_log_fp so the last record survives a clean exit. */
void final_log_flush(void);

/* W18-I: cudaDeviceReset() to release the device context immediately and
 * close the "phantom 100% util" artifact on nvidia-smi after exit. */
void kt_cuda_cleanup_atexit(void);

/* ---- Signal-handler installer ---- */

/* sigaction(SIGINT|SIGTERM|SIGHUP) → signal_handler; returns 0 on success,
 * -1 on failure (after printing diagnostic to stderr).  SIGHUP added in
 * W19-B-4 so tmux detach / ssh disconnect / supervisord stop drain
 * gracefully. */
int install_signal_handlers(void);

/* ---- Fatal-cleanup helper for trip-wire paths ---- */

/* W19-B-1: write(2) `msg` to stderr (async-signal-safe), call
 * cudaDeviceReset(), then _exit(code).  Use this instead of abort() from
 * W18-A alignment / W18-K trip-wire / W19-A divergence paths so the GPU
 * context is released before exit (abort() skipped atexit handlers and
 * left the context warm). */
void kt_fatal_cleanup(int code, const char *msg);

#ifdef __cplusplus
}
#endif

#endif /* KT_SIGNAL_H */
