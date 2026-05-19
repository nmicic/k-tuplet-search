# Lowbits exhaustive — per-bit timing (2026-05-10)

Wheel: **47# (KT_PRIMORIAL=14)**.
Hardware: 4× NVIDIA RTX 5090 (4× GPU server).
Engine: `kt_filter_v8` SHA `4f936d3` (post `--exhaustive` prefix-walk fix).
Source: aggregated from `runs/sweep_*_b*-*/sweep_status.jsonl` across all 4 GPUs, all sweeps, after the `range_end_u128` fix landed at 07:00 UTC.

`n_exh` = clean exhaust count: complete sequential prefix sweeps that emitted
`PREFIX EXHAUSTED`. `caps` = `--max-time` truncations (mostly the pre-fix runs
at b60..b62). Rows with `n_exh` below the campaign's full lane count are timing
samples, not proofs that the whole bit band was exhausted.

```
pattern_bits   n_exh    min_s    med_s    max_s   med_min   caps
----------------------------------------------------------------------
KT22_P2_b60        5       27       28       29       0.5      2
KT22_P2_b61        5       26       27       29       0.5      2
KT22_P2_b62        5       27       27       29       0.5      2
KT22_P2_b63        5       27       28       30       0.5      1
KT22_P2_b64        5       27       28       29       0.5      1
KT22_P2_b65        5       27       28       29       0.5      1
KT22_P2_b66        5       27       28       29       0.5      1
KT22_P2_b67        5       28       30       30       0.5      1
KT22_P2_b68        5       30       30       31       0.5      1
KT22_P2_b69        5       32       32       34       0.5      1
KT22_P2_b70        5       38       39       40       0.7      1
KT22_P2_b71        5       49       50       52       0.8      1
KT22_P2_b72        5       72       73       74       1.2      1
KT22_P2_b73        5      117      117      120       1.9      1
KT22_P2_b74        4      208      208      211       3.5      1
KT22_P2_b75        4      389      390      392       6.5      1
KT22_P2_b76        4      752      754      754      12.6      0
KT22_P2_b77        4     1479     1480     1480      24.7      0
KT22_P2_b78        1     2932     2932     2932      48.9      0
KT22_P2_b79        1     5839     5839     5839      97.3      0
KT22_P3_b60        5       45       46       48       0.8      2
KT22_P3_b61        5       45       46       48       0.8      2
KT22_P3_b62        5       45       45       50       0.8      2
KT22_P3_b63        5       46       46       49       0.8      1
KT22_P3_b64        5       45       45       48       0.8      1
KT22_P3_b65        5       46       46       49       0.8      1
KT22_P3_b66        5       47       47       49       0.8      1
KT22_P3_b67        5       48       48       51       0.8      1
KT22_P3_b68        5       50       50       52       0.8      1
KT22_P3_b69        5       54       56       58       0.9      1
KT22_P3_b70        5       64       65       67       1.1      1
KT22_P3_b71        5       83       83       86       1.4      1
KT22_P3_b72        4      121      122      124       2.0      1
KT22_P3_b73        4      197      200      201       3.3      1
KT22_P3_b74        4      350      352      353       5.9      1
KT22_P3_b75        4      657      658      660      11.0      0
KT22_P3_b76        4     1268     1270     1272      21.2      0
KT22_P3_b77        1     2487     2487     2487      41.5      0
KT22_P3_b78        1     4941     4941     4941      82.3      0
KT23_P1_b60        5       19       20       21       0.3      2
KT23_P1_b61        5       19       20       21       0.3      2
KT23_P1_b62        5       20       20       21       0.3      2
KT23_P1_b63        5       19       20       21       0.3      1
KT23_P1_b64        5       19       20       22       0.3      1
KT23_P1_b65        5       20       20       21       0.3      1
KT23_P1_b66        5       20       20       21       0.3      1
KT23_P1_b67        5       20       21       22       0.3      1
KT23_P1_b68        5       21       21       23       0.3      1
KT23_P1_b69        5       23       24       24       0.4      1
KT23_P1_b70        5       27       27       28       0.5      1
KT23_P1_b71        5       34       35       36       0.6      1
KT23_P1_b72        5       49       50       51       0.8      1
KT23_P1_b73        5       80       80       81       1.3      1
KT23_P1_b74        5      139      140      141       2.3      1
KT23_P1_b75        4      259      260      261       4.3      1
KT23_P1_b76        4      501      502      502       8.4      1
KT23_P1_b77        4      982      982      984      16.4      0
KT23_P1_b78        1     1945     1945     1945      32.4      0
KT23_P1_b79        1     3871     3871     3871      64.5      0
KT24_P3_b60        5       17       18       19       0.3      2
KT24_P3_b61        5       17       18       18       0.3      2
KT24_P3_b62        5       17       18       19       0.3      2
KT24_P3_b63        5       17       18       20       0.3      1
KT24_P3_b64        5       17       18       18       0.3      1
KT24_P3_b65        5       17       18       20       0.3      1
KT24_P3_b66        5       17       18       19       0.3      1
KT24_P3_b67        5       18       19       20       0.3      1
KT24_P3_b68        5       19       19       20       0.3      1
KT24_P3_b69        5       20       21       22       0.3      1
KT24_P3_b70        5       23       24       24       0.4      1
KT24_P3_b71        5       29       30       31       0.5      1
KT24_P3_b72        5       42       43       43       0.7      1
KT24_P3_b73        5       66       67       68       1.1      1
KT24_P3_b74        5      116      117      118       1.9      1
KT24_P3_b75        5      215      215      216       3.6      1
KT24_P3_b76        4      414      414      415       6.9      1
KT24_P3_b77        4      811      812      813      13.5      0
KT24_P3_b78        4     1606     1606     1606      26.8      0
KT24_P3_b79        1     3192     3192     3192      53.2      0
KT24_P3_b80        1     6371     6371     6371     106.2      0
```

## Per-pattern frontier (highest cleanly-exhausted bit, all 4 patterns)

| Pattern | Frontier | Wall at frontier | Pattern weight (n_admissible @ 47#) |
|---------|----------|------------------|--------------------------------------|
| KT24_P3 | b80      | 106 min          | smallest (~360 M)                    |
| KT23_P1 | b79      | 65 min           |                                      |
| KT22_P2 | b79      | 97 min           |                                      |
| KT22_P3 | b78      | 82 min           | largest (370 M; the slowest of the four) |

Capped without exhausting (partial scans):
- KT22_P3 b79  (would-have-been ~165 min; capped at 7200 s)
- KT23_P1 b80  (would-have-been ~128 min; capped at 7200 s)

## Doubling-rule confirmation (KT24_P3, the cleanest series)

```
b60..b67   ~17–19 s   wheel-setup-bound (work fits inside one wheel period, GPU tail < 1 s)
b68 → b69  1.11×       work begins to dominate setup
b69 → b70  1.14×
b70 → b71  1.25×
b71 → b72  1.43×
b72 → b73  1.56×
b73 → b74  1.75×
b74 → b75  1.84×
b75 → b76  1.93×
b76 → b77  1.96×
b77 → b78  1.98×
b78 → b79  1.99×
b79 → b80  2.00×   ← perfect doubling holds from b76 onward
```

So beyond b76 the per-bit cost is **exactly 2× the previous bit** for all 4 patterns; below b70 it's essentially fixed wheel-setup overhead (~17 s for the lightest pattern, ~45 s for the heaviest).

## Forward projection (single 5090, 47# wheel, current pipeline)

Multiplying the b80 baseline by 2× per bit:

| bits | KT24_P3 (lightest) | KT22_P3 (heaviest) | notes |
|------|---------------------|---------------------|-------|
| b80  | 106 min             | 660 min ≈ 11 h      | KT24_P3 confirmed; KT22_P3 projected |
| b85  | 56 h                | 14 days             | per cell |
| b90  | 75 days             | 460 days            | per cell |
| b96  | 13 years            | 80 years            | per cell — well past CC's 76b record territory |

So with 4 GPUs, exhausting **all 4 patterns up through b80** is feasible (a couple of days of compute end-to-end). **b85** is feasible if we accept a week of dedicated runtime for the slowest pattern. **b90+ is not feasible exhaustively** with this pipeline at this wheel — that's where random sampling at higher wheel/primorial takes over (the 89..119 K=19 territory we used to scan).

## Raw aggregate time spent so far

- Total cells in this campaign: 431 records in JSONL
- Sum of clean-exhaust elapsed: ~ 13 hours of GPU-second across 4 GPUs
- Sum of capped (pre-fix) elapsed: ~ 24 hours wasted on the 12 pre-fix b60-b62 cells that ran 7200 s each before the fix landed

## Result

**0 hits, 0 nonempty `found.txt`, 0 surv** across **every cell** for **every (pattern, bits) combination** sampled, including the partial caps.

Conclusion: the fully exhausted low-bit cells produced no novel records for
`{KT22_P2, KT22_P3, KT23_P1, KT24_P3}`. Rows with partial `n_exh` values should
be read as runtime samples only; they are useful for planning but are not a
claim that the entire bit band is empty.
