/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_tests.h — forward declarations for the partial Step 8 extract.
 * 17 host-only tests live in kt_tests.cu and are called from the
 * run_unit_tests dispatcher that stays in kt_filter_v8.cu (alongside
 * the ~33 kernel-launching tests that nvcc requires to share a TU with
 * the kernels they fire — see kt_tests.cu for rationale).
 */
#ifndef KT_TESTS_H
#define KT_TESTS_H

#ifdef __cplusplus
extern "C" {
#endif

int test_t1_parse_all_cpu_flags(void);
int test_t4_banner_ignored_flags(void);
int test_t5_forbidden_kt5_q7(void);
int test_t6_kt5_wheel_hash(void);
int test_t9_forbidden_mask_u64(void);
int test_t16_records_load_and_contains(void);
int test_t19_prefix_range_math(void);
int test_t26_warning_bits127_fermat(void);
int test_t27_warning_bits_low_line(void);
int test_t32_u128_format_dec_helper(void);
int test_t33_bloom_revisit_detection(void);
int test_t37_list_patterns(void);
int test_t46_seed_anchor_placement(void);
int test_t46b_lane_min_primorial_alignment(void);
int test_t46c_lane_start_primorial_alignment(void);
int test_t47_records_json_env_override(void);
int test_t48_kpi_target_base_parse(void);
int test_t50_wheel_expr_parser(void);

#ifdef __cplusplus
}
#endif

#endif /* KT_TESTS_H */
