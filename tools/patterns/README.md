# tools/patterns — admissible prime k-tuplet pattern utilities

Self-contained tooling for verifying, enumerating, and reporting on admissible prime k-tuplet patterns. Output is JSON, for engine consumption.

**Authoritative reference for the underlying math**: Norman Luhn's [https://pzktupel.de/ktpatt_hl.php](https://pzktupel.de/ktpatt_hl.php) — admissible patterns and Hardy-Littlewood constants for k=2..50. These tools emit the same patterns in machine-readable JSON form; they are not peer-reviewed and may have bugs. Cross-check against ktpatt_hl.php before relying on any output.

**Full documentation**: see [`../../docs/PATTERN_TOOLS.md`](../../docs/PATTERN_TOOLS.md).

## Quick reference

```bash
# Verify a pattern is admissible
python3 validate_pattern.py --pattern-name KT19_P0
python3 validate_pattern.py --offsets "0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76"

# Enumerate all admissible canonical patterns at given (k, diameter)
python3 enumerate_patterns.py --auto-h-k --k 22 --workers 8

# Same but ~250x faster (compiled C)
make
./pattern_enum --k 22 --diameter 90 --threads 32

# Output formats: json (default), tsv, txt, gp, header
./pattern_enum --k 22 --diameter 90 --format header --with-reflections

# Compare engine catalog (KT_PATTERNS[]) against full enumeration
python3 catalog_gap_report.py --output ../../reports/catalog_completeness.md

# Property tests (15 invariants)
python3 test_pattern_tools.py

# Low-bit-range scan for sporadic high-k tuplets
python3 low_bit_scan.py --pattern-name KT22_P0 --max-bits 48
```

## Files

| file | purpose |
|---|---|
| `validate_pattern.py` | admissibility + canonical form + singular series for any pattern |
| `enumerate_patterns.py` | exhaustive enumeration at (k, diameter); reference impl |
| `pattern_enum.c` | C99 + OpenMP port of enumerate_patterns.py (~250× faster) |
| `Makefile` | builds `pattern_enum` |
| `catalog_gap_report.py` | compares `KT_PATTERNS[]` to enumeration; finds coverage gaps |
| `low_bit_scan.py` | exhaustive scan of [0, 2^B) for sporadic high-k tuplets (prototype) |
| `test_pattern_tools.py` | 15 property/integration tests |

All Python tools: stdlib only (no sympy, no numpy required).
C tool: stdlib + libgomp (standard with gcc).

## Testing

```bash
make test                            # 14/14 self-tests via C tool
python3 test_pattern_tools.py        # 15/15 cross-tool property tests
```

## Status of this folder

Convenience tooling. Output (`--format header`) regenerates rows for `src/common/ktuplet_pattern.c` `KT_PATTERNS[]`, closing the enumeration → engine catalog loop. The math (admissibility, canonical form, singular series) follows standard definitions; the implementation is not peer-reviewed.

For any external publication or cross-validation, use [pzktupel.de/ktpatt_hl.php](https://pzktupel.de/ktpatt_hl.php) as the source of truth.
