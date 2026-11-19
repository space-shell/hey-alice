# NX1 device bring-up toolkit

Runbook for preparing the Bluefox NX1 (MediaTek MT6769, Android 15, A/B
partitions, 4.0" 540×1168) for root and hey-alice development. Plan refs:
`docs/plan.md` §M0, §D1.1, §D1.2, ADR-1. Hard rule for the bring-up run:
**read-only against the device** — no unlock, no flash, no writes.

## Layout

| File | Purpose |
| --- | --- |
| `flake.nix` | devshell: adb/fastboot, mtkclient, scrcpy, curl/unzip/jq |
| `backup.sh` | 2-pass mtkclient partition backup (read + verify), READ-ONLY |
| `patch-init-boot.sh` | Magisk-patch `init_boot` PC-side from the backup |
| `verify-root.sh` | post-flash root verification gates |
| `unlock-flash.sh` | unlock + init_boot flash sequence (**future session only**) |
| `post-root-setup.sh` | battery exemption, debloat, side-key getevent logging |

Everything runs inside the devshell: `cd tools && nix develop`.

## Prerequisites

### udev (owner's NixOS config, no sudo from agents)

```nix
programs.adb.enable = true;                          # adb/fastboot rules + adbusers group
services.udev.packages = [ pkgs.mtkclient ];         # BROM-mode rules (already installed on this machine)
users.users.jamesnicholls.extraGroups = [ "adbusers" ];  # or plugdev equivalent
```

Then `nixos-rebuild switch` (sudo) **and log out/in** — group membership needs a
new login session. Check: `nix develop -c adb devices -l` must show the NX1
with state `device` (not `no permissions`, not `unauthorized`).

### USB debugging RSA

First `adb devices` after each wipe pops "Allow USB debugging?" on the phone —
the owner taps it. Authorizations are per-host-key and survive reboots but not
wipes (the unlock session re-triggers the prompt).

### BROM mode (for all mtkclient work)

mtkclient talks to the Boot ROM before Android loads. Physical entry, done by
the owner (the scripts print this and then wait for the device):

1. unplug the USB cable
2. power OFF (hold power → shutdown)
3. press and **hold Vol+ + Vol−**
4. keep holding while plugging USB back in (~5 s)
5. release once mtkclient logs `PreLoader` / starts the read

Serial observed on this host: `TLF2601S000307`.

## Backup (D1.1 — do first, everything depends on it)

```sh
cd tools && nix develop
../tools/backup.sh read     # BROM session 1: all partitions except userdata + preloader
../tools/backup.sh verify   # BROM session 2: independent re-read, hash compare
../tools/backup.sh status   # offline summary
```

- Output: `.backups/nx1-<date>/` — `<partition>.img` files, `preloader.img`,
  `MANIFEST.sha256` (sha256sum format), `mtk-read.log`/`mtk-verify.log`.
- Verify is strict: every file re-read in a second BROM session must hash-match
  and the file set must be identical. Any mismatch → `VERIFY-FAILED.txt`, exit 1,
  **no VERIFIED marker** — never unlock/flash against an unverified backup.
- `MANIFEST.sha256` and the `VERIFIED` marker are committed; the images stay
  local (gitignored — multi-GB and private).
- ~10 GB to read, twice. Budget 30–90 min depending on USB throughput.
- Restore/unbrick path (future sessions only): `mtk w <partition> <file>` from
  BROM; full-firmware restore via mtkclient/SP Flash Tool. The backup covers
  every GPT partition + preloader, so any single-partition or full restore is
  possible except `userdata` (owner data — disposable by owner's decision).

## Magisk-patched init_boot

Root goes into `init_boot` (ramdisk), never `boot` — the NX1 boot partition is
gzip-compressed and Google GKI images break WiFi (plan R8, TrebleDroid wiki).

```sh
../tools/patch-init-boot.sh            # uses newest VERIFIED backup's init_boot_a.img
# or: ../tools/patch-init-boot.sh path/to/init_boot_a.img
```

- Downloads the pinned official Magisk release APK (v31.1, GitHub), extracts
  `magiskboot` (x86_64 host tool) + arm64 payload binaries, runs upstream
  `boot_patch.sh` with app-default flags (`KEEPVERITY=true KEEPFORCEENCRYPT=true`,
  `PREINITDEVICE=metadata`), verifies the result carries the Magisk ramdisk
  signature, writes `magisk-patched-init_boot.img` + `PATCHED-INIT_BOOT.txt`
  (sha256 provenance) next to the backup.
- **Magisk-app fallback** (if PC-side plumbing fights): copy
  `.backups/nx1-<date>/init_boot_a.img` to the phone (Files app or `adb push`),
  install `Magisk-v31.1.apk`, Magisk → Install → **Select and Patch a File** →
  pick `init_boot_a.img` → it writes `magisk_patched-<random>.img` in Download →
  `adb pull` it to `.backups/nx1-<date>/magisk-patched-init_boot.img` and record
  its sha256 in `PATCHED-INIT_BOOT.txt` (same layout the scripts expect).

## Unlock + root session (future — owner physically present)

`tools/unlock-flash.sh` encodes the full gated sequence; do not run it in the
bring-up run. What it will ask of the owner:

1. wipe consent (it refuses to start without the VERIFIED backup + provenance-
   recorded patched image + explicit `UNLOCK`/env confirmation)
2. `adb reboot bootloader` → `fastboot flashing unlock` → **volume-up + power**
   on the on-screen confirm → device wipes, reboots
3. post-wipe setup: skip the wizard, re-enable Developer options → USB
   debugging + OEM unlocking, accept the RSA prompt
4. second reboot to bootloader → unlock state verified → `fastboot flash
   init_boot magisk-patched-init_boot.img` → reboot
5. `tools/verify-root.sh` gates: boot completed, unlocked props, `su` uid 0,
   magisk binary, manager app, `/data/adb`

Bootloop safety: if boot doesn't complete in ~5 min, enter BROM and restore
`mtk w init_boot .backups/nx1-<date>/init_boot_a.img` (a write session — only
valid because the backup is VERIFIED).

## Post-root (D1.2/D1.7 prep)

```sh
../tools/post-root-setup.sh battery-exempt   # deviceidle whitelist + appops for com.heyalice
../tools/post-root-setup.sh debloat          # no-op until bloat observed
../tools/post-root-setup.sh sidekey-log 30   # owner presses short/long/double; getevent -lt log
```

The side-key log (filtered `KEY_`/`BTN_` lines) is the D1.2 keycode contract
input — capture it in the root session and commit the filtered summary under
`logs/`.

## Reference sources

- TrebleDroid/treble_experimentations wiki — Bluefox NX1 device page
- bluefox-guide.neocities.org — bootloader unlock, firmware restore, battery saving
- Firmware payload: not downloaded yet — see `docs/plan.md` D1.1 note; opportunistic extra

## State log

| Date | State |
| --- | --- |
| 2026-11-19 | toolkit committed; adb blocked on `programs.adb.enable` udev step; backup pending |
