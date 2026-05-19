/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_signal.cu — signal handler, atexit hooks, and fatal-cleanup helper.
 * Bodies moved verbatim from kt_filter_v8.cu in W20-DEC Phase 3 Step 6.
 *
 * Lives as a .cu (not .c) only because kt_cuda_cleanup_atexit calls
 * cudaDeviceReset() and kt_fatal_cleanup() needs the same.  The
 * signal_handler / install_signal_handlers / final_log_flush bodies
 * would compile fine as C, but folding them into the same TU keeps the
 * "signal + cleanup" concern in one place.
 */
#include "kt_signal.h"

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>         /* write(2), _exit, fsync, fileno */
#include <signal.h>

/* atexit-registered: flush the log file so the last record survives a clean
 * exit. SIGINT path also flushes via the signal handler. */
void final_log_flush(void) {
    if (g_log_fp) {
        fflush(g_log_fp);
#ifdef __linux__
        fsync(fileno(g_log_fp));
#endif
    }
}

static void signal_handler(int sig) {
    (void)sig;
    /* W18-I (multi-angle N5): async-signal-safe — assigning to a
     * volatile sig_atomic_t is the ONLY thing POSIX guarantees from a
     * signal handler.  final_log_flush() calls fflush/fsync, which are
     * NOT async-signal-safe (libc may hold internal locks).  The graceful
     * exit path in main() / run_search_loop()'s atexit handler flushes
     * the log on shutdown; we just need the loop to notice the flag. */
    g_shutdown_requested = 1;
}

int install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGINT, &sa, NULL) != 0) {
        fprintf(stderr, "ERROR: sigaction(SIGINT) failed: %s\n", strerror(errno));
        return -1;
    }
    if (sigaction(SIGTERM, &sa, NULL) != 0) {
        fprintf(stderr, "ERROR: sigaction(SIGTERM) failed: %s\n", strerror(errno));
        return -1;
    }
    /* W19-B-4 (multi-angle P1-20): SIGHUP — sent by tmux session detach,
     * ssh disconnect, supervisord stop.  Default disposition terminates;
     * we want the same graceful drain as SIGINT/SIGTERM (W18-B drain-
     * boundary ckpt save + W18-I CUDA cleanup). */
    if (sigaction(SIGHUP, &sa, NULL) != 0) {
        fprintf(stderr, "ERROR: sigaction(SIGHUP) failed: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

/* W18-I (multi-angle N4): atexit-registered CUDA cleanup.  Without this, a
 * clean process exit leaves the CUDA context on the device — the driver
 * holds SM counters and pinned-memory mappings until the host kernel
 * eventually reaps them.  Observable as "phantom 100% util" on nvidia-smi
 * for several seconds (sometimes minutes) after the engine has exited.
 *
 * Calling cudaDeviceReset() in atexit forces the driver to release the
 * context immediately; subsequent nvidia-smi samples report the expected
 * 0% util.  cudaDeviceReset() also implicitly synchronizes + destroys all
 * streams and frees all pinned host memory in the current context, so this
 * is sufficient on its own; we don't need to iterate the per-stream
 * cleanup that run_search_loop()'s post-loop block already does on the
 * graceful path.
 *
 * Registration order at main(): final_log_flush first, kt_cuda_cleanup_atexit
 * after.  LIFO atexit popping then runs CUDA cleanup before log flush.  We
 * accept that ordering (CUDA reset is fast and bounded; log flush can in
 * theory wedge on a stuck filesystem). */
void kt_cuda_cleanup_atexit(void) {
    /* W19-B-5: destroy the W18-K counter stream if run_search_loop's own
     * teardown didn't run (e.g., SIGINT mid-loop, exit() from a different
     * path).  cudaDeviceReset below would release it anyway; we mirror
     * the explicit destroy for symmetry with run_search_loop's path. */
    if (s_w19b_counter_stream) {
        cudaStreamDestroy(s_w19b_counter_stream);
        s_w19b_counter_stream = 0;
    }
    /* cudaDeviceReset returns void in older CUDA, cudaError_t in newer.
     * We don't care about its return; the next process to touch the GPU
     * gets a fresh context regardless. */
    (void)cudaDeviceReset();
}

/* W19-B-1 (multi-angle P1-4): fatal-cleanup helper for trip-wire paths
 * (W18-A alignment assertion, W18-K future trip-wires).  Previously these
 * called abort(), which skips atexit handlers — the CUDA context would
 * stay warm, re-triggering the phantom-util artifact that W18-I closed on
 * graceful exits.
 *
 * kt_fatal_cleanup writes `msg` to stderr via write(2) (async-signal-safe
 * vs fprintf, which is what a trip-wire context wants), calls
 * cudaDeviceReset() to release the device context, then _exit(code).
 * _exit (not exit) skips atexit handlers — that's intentional, since we
 * just did the only cleanup work that matters (CUDA reset) and don't want
 * fflush/fsync hangs to block context release. */
void kt_fatal_cleanup(int code, const char *msg) {
    if (msg) {
        size_t n = 0; while (msg[n]) n++;
        ssize_t wr = write(2, msg, n);  /* async-signal-safe vs fprintf */
        (void)wr;
    }
    /* Best-effort GPU cleanup; W18-I's atexit handler covers clean exits,
     * but kt_fatal_cleanup runs from contexts (alignment trip-wire, W19-A
     * W18-K trip-wire) where abort() previously skipped atexit. */
    (void)cudaDeviceReset();
    _exit(code);
}
