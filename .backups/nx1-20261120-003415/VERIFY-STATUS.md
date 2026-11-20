# Verify status — NX1 backup `.backups/nx1-20261120-003415/`

**FINAL STATE (2026-11-20): VERIFIED, with `super.bin` UNVERIFIED (warn-level).**
See `VERIFIED` marker, `VOLATILE-HASHES.txt`, `SUPER-TIEBREAK.txt`.

Device: Bluefox NX1, serial `TLF2601S000307`, slot `a`. Backup = mtkclient
BROM reads, all partitions except `userdata`, + eMMC Boot1 preloader.
Manifest: `MANIFEST.sha256` (53 partition dumps + `preloader-boot1.bin` = 54
entries). Read throughput 6–11 MB/s; full pass ≈ 20–25 min.

## Attempt history

| # | When | Result |
| --- | --- | --- |
| read session | 2026-11-20 09:15–09:39 | ✅ complete: 53 GPT partitions + Boot1 preloader (`preloader` phase). Manifest committed at this state. |
| verify attempt 1 | 2026-11-20 ~11:48 | ❌ invalid — started against a stale-attach session, re-read produced only the Boot1 file; compare reported everything missing. Superseded. |
| verify attempt 2 | 2026-11-20 ~11:55–12:15 | ⚠️ complete re-read finished on disk; the in-script compare was killed by overlapping-process cleanup (two verify chains fought — fixed by the flock single-instance guard in `backup.sh`). Files used for the offline compare below. |
| Boot1 re-read | 2026-11-20 | ✅ `preloader-boot1.bin` MATCH — preloader 2-pass verified. |
| super tie-break | 2026-11-20 13:46 | ⚠️ `SUPER UNVERIFIED` (see below). |

## Final per-category table

| Category | Files | Result |
| --- | --- | --- |
| Flash-critical (`boot_a/b`, `init_boot_a/b`, `vbmeta_a/b`, `vendor_boot_a/b`, `lk_a/b`, `tee_a/b`, `gpt`, `gpt_backup`, `seccfg`, `proinfo`) + `preloader-boot1.bin` | 17 | ✅ **all bit-identical across reads** (re-checked on disk vs manifest at closure) |
| Other static (`misc`-class small partitions: `para`, `frp`, `md_udc`, `boot_para`, `logo`, `sec1`, `nvcfg`-family non-volatile remainder, `otp`, `flashinfo`, `mrdump`, …) | 28 | ✅ bit-identical (43 total exact incl. flash-critical, offline compare of the complete re-read) |
| Volatile | 8 | ⚠️ differ between reads (phone booted Android between passes): `expdb`, `metadata`, `misc`, `nvcfg`, `nvdata`, `persist`, `protect1`, `protect2` — old/new hashes in `VOLATILE-HASHES.txt`. Expected runtime churn; never a failure. |
| `super.bin` | 1 | ⚠️ **UNVERIFIED** — tie-break evidence below. WARN-level: does not affect init_boot flashing; matters only for a hypothetical full-`super` restore. |

## super.bin tie-break evidence

Three full-size reads (9,663,676,416 B each), no majority:

| read | sha256 |
| --- | --- |
| #1 (manifest, on disk) | `8f29211ef6cb14ef6079d32001888b8286a44129fb13a736f235c595041c9bfa` |
| #2 (verify re-read) | `d06193ef01d4014af889623160eef03a977fd9bb12aec3152c17d4232fb260d2` |
| #3 (tie-break) | `7c62f84766c58c52a5027ee4ac2700a470f78d0ae469188381ebed47b23c1729` |

First-difference offsets (1-based): read1↔read2 at byte 1,223,987,201;
read2↔read3 and read1↔read3 both at byte 2,098,181 (≈ 2 MiB — exactly where
super's dynamic-partition payload starts; the metadata region 0–2 MiB is
identical across all three reads). The differing regions **move between
reads** — no fixed rewritten region — so per-read instability over a marginal
USB link is the leading explanation, not flash writes.

**Recommendation:** if a full `super` restore is ever needed, re-read super
twice on a different cable/port and require a 2-of-3 majority before writing.
No further reads now — zero impact on the Alice project (root path flashes
`init_boot` only).

## Tooling hardened during this session (all committed)

- `backup.sh`: flock single-instance guard + pgrep mtk check; `VOLATILE` list
  with side-by-side `VOLATILE-HASHES.txt` recording; verify rl auto-retry;
  BROM-entry guard blocking on every non-BROM MediaTek PID (adb `201c`,
  preloader `2000/2001`) — only real BROM (`0003`) or a detached bus passes.
- `super-tiebreak.sh`: 3-way verdict script (used for the verdict above).
- `unlock-flash.sh`: flash-critical set manifest-checked on disk at start;
  super risk is documentation, not a gate.
