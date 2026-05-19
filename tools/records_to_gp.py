#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
records_to_gp.py — convert records.json to gp/records.gp for use in kt_lib_v1.gp.

Run from repo root:
    python3 tools/records_to_gp.py

Output format: GP list KT_RECORDS where each entry is
    [k, [[base_str, [offsets], digits, "date", "author"], ...]]
sorted by k ascending.
"""

import json
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECORDS_JSON = os.path.join(REPO_ROOT, "known", "records.json")
OUT_GP = os.path.join(REPO_ROOT, "gp", "records.gp")

def gp_str(s):
    """Escape a Python string for a GP string literal."""
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def main():
    with open(RECORDS_JSON) as f:
        data = json.load(f)

    lines = []
    lines.append("/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>")
    lines.append(" * SPDX-License-Identifier: Apache-2.0 */")
    lines.append("/* gp/records.gp — auto-generated from records.json by tools/records_to_gp.py.")
    lines.append(" * Do not edit by hand. Format: KT_RECORDS[i] = [k, list_of_record_vectors]")
    lines.append(" * Each record vector: [base_str, [offsets], digits, date_str, author_str] */")
    lines.append("")

    entries = []
    for k_str, v in sorted(data.items(), key=lambda x: int(x[0])):
        k = int(k_str)
        rec_gp_list = []
        for rec in v["records"]:
            base = rec["base"]
            offsets = rec["offsets"]
            digits = rec["digits"]
            date = rec["date"]
            author = rec["author"]
            offsets_gp = "[" + ", ".join(str(o) for o in offsets) + "]"
            rec_gp = f"[{gp_str(base)}, {offsets_gp}, {digits}, {gp_str(date)}, {gp_str(author)}]"
            rec_gp_list.append(rec_gp)
        recs_joined = ",\n    ".join(rec_gp_list)
        entries.append(f"[{k},\n  [\n    {recs_joined}\n  ]\n]")

    lines.append("{")
    lines.append("KT_RECORDS = [")
    lines.append(",\n".join(entries))
    lines.append("];")
    lines.append("} \\\\ end KT_RECORDS block")
    lines.append("")

    with open(OUT_GP, "w") as f:
        f.write("\n".join(lines))

    total = sum(len(data[k]["records"]) for k in data)
    print(f"Wrote {len(data)} k-values, {total} records to {OUT_GP}")

if __name__ == "__main__":
    main()
