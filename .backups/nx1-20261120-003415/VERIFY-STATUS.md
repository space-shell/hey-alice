# Verify status — NX1 backup `.backups/nx1-20261120-003415/`

Device: Bluefox NX1, serial `TLF2601S000307`, slot `a`. Backup = mtkclient
BROM reads, all partitions except `userdata`, + eMMC Boot1 preloader.
Manifest: `MANIFEST.sha256` (53 files + Boot1 preloader = 54 entries).
Read throughput 6–11 MB/s; full pass ≈ 20–25 min.

## Attempt history

| # | When | Result |
| --- | --- | --- |
| read session | 2026-11-20 09:15–09:39 | ✅ complete: 53 GPT partitions + Boot1 preloader (via `preloader` phase). Manifest committed at this state. |
| verify attempt 1 | 2026-11-20 ~11:48 | ❌ invalid — started against a stale-attach session, re-read produced only the Boot1 file; compare reported everything missing. Superseded; `.verify` wiped by later attempts. |
| verify attempt 2 | 2026-11-20 ~11:55–12:15 | ⚠️ partial — full re-read completed on disk, but the compare was killed by an overlapping-process cleanup (two verify chains fought; fixed by the single-instance flock guard). Offline hash-compare of the complete re-read used as evidence (see below). |
| super tie-break | pending | 3rd read of `super.bin` running (`.verify3/`); verdict lands in `SUPER-TIEBREAK.txt`. |

## Offline compare of attempt 2's complete re-read vs manifest (53 files)

- **43/53 bit-identical**, including every flash-critical partition:
  `boot_a/b`, `init_boot_a/b`, `vbmeta_a/b`, `vbmeta_system_a/b`,
  `vbmeta_vendor_a/b`, `vendor_boot_a/b`, `lk_a/b`, `tee_a/b`, `preloader-boot1`.
- **8 volatile partitions differ** (expected — the phone booted Android between
  reads): `expdb`, `metadata`, `misc`, `nvcfg`, `nvdata`, `persist`,
  `protect1`, `protect2`. Now formalized as the `VOLATILE` list in
  `backup.sh`; future verifies record old/new hashes side-by-side in
  `VOLATILE-HASHES.txt` instead of failing.
- **`super.bin` differs** in a small byte cluster ~1.14 GB in (both reads
  full size, 9,663,676,416 B). Ambiguous (USB glitch vs genuine write) →
  tie-break 3rd read; verdict in `SUPER-TIEBREAK.txt`.

## Verdict semantics

- Static-partition hash mismatch = FAIL (blocks `VERIFIED`).
- Volatile mismatch = WARN, recorded, never fails.
- `super.bin` = tie-break verdict only; worst case WARN-level UNVERIFIED —
  it does not block root flashing (`unlock-flash.sh` gates on the
  flash-critical set: boot/init_boot/vbmeta/preloader, all verified OK).
