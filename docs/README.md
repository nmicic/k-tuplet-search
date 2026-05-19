# docs/ - design notes and reference material

This directory contains human-facing design and background documentation. It is
separate from command-oriented HOWTO files in the repository root and engine
subdirectories.

## Documents

| File | Purpose |
|---|---|
| `CUDA_CLI_REFERENCE.md` | Long-form `kt_filter_v8` command-line reference |
| `KT_PIPELINE.md` | Current search pipeline overview |
| `PATTERN_TOOLS.md` | Detailed guide for pattern validation/enumeration tools |

## Reading Order

For a new reader:

1. Start with [`../README.md`](../README.md) for project scope.
2. Use [`../HOWTO.md`](../HOWTO.md) for GPU engine commands.
3. Use [`CUDA_CLI_REFERENCE.md`](CUDA_CLI_REFERENCE.md) when you need exact option meanings.
4. Read [`KT_PIPELINE.md`](KT_PIPELINE.md) for architecture.
5. Read [`PATTERN_TOOLS.md`](PATTERN_TOOLS.md) before changing the pattern catalog.

The authoritative mathematical reference for patterns and Hardy-Littlewood
constants is Norman Luhn's
[ktpatt_hl.php](https://pzktupel.de/ktpatt_hl.php).
