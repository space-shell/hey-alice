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

- Output: `.backups/nx1-<date>/` — `<partition>.bin` files (mtkclient's naming),
  `preloader-boot1.bin` (eMMC Boot1 = the real preloader), `otp.bin`,
  `flashinfo.bin`, `gpt.bin`, `MANIFEST.sha256` (sha256sum format), and mtk
  logs. `.state`/`hwparam.json` are mtkclient session artifacts — on disk but
  excluded from the manifest.
- Each phase needs BROM entries: `read` = 2 (rl pass + Boot1 read), `verify` =
  2, `preloader` = 1. The script prompts between passes and waits for the
  device itself; **unplug the phone when it asks** — mtkclient grabs a running
  phone (0e8d:201c) and handshake-fails forever instead of waiting for BROM.
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
../tools/patch-init-boot.sh            # patches BOTH slots from the newest backup
# or: ../tools/patch-init-boot.sh --allow-unverified   # before VERIFIED exists (explicit order only)
# or: ../tools/patch-init-boot.sh path/to/init_boot_a.bin
```

- Downloads the pinned official Magisk release APK (v31.1, GitHub), extracts
  `magiskboot` (x86_64 host tool) + arm64 payload binaries, runs the APK's own
  `boot_patch.sh` with app-default flags (`KEEPVERITY=true
  KEEPFORCEENCRYPT=true`, `PREINITDEVICE=metadata`), verifies each result
  carries the Magisk ramdisk signature, and writes per-slot images + provenance
  next to the backup:
  - `init_boot_a.magisk.img` / `init_boot_b.magisk.img` (sha256 in
    `PATCHED-INIT_BOOT.txt`, gitignored with the other images)
- **Which slot gets flashed: the CURRENT one, picked at flash time.** The NX1
  is A/B; at bring-up the active slot is `a` (`ro.boot.slot=a`, confirmed
  2026-11-19) and a wipe does not switch slots — but `unlock-flash.sh` does not
  assume it: after rebooting to bootloader it reads `fastboot getvar
  current-slot` and flashes `init_boot_<slot>.magisk.img`. Both slots are
  patched so any active slot is covered, and each image embeds the SHA1 of its
  own stock source.
- `verify-root.sh` remains the post-flash gate; `unlock-flash.sh` refuses to
  flash unless the backup has `VERIFIED` and the image hash is recorded in
  `PATCHED-INIT_BOOT.txt`.
- **Magisk-app fallback** (if PC-side plumbing fights): copy
  `.backups/nx1-<date>/init_boot_a.bin` to the phone (Files app or `adb push`),
  install `Magisk-v31.1.apk`, Magisk → Install → **Select and Patch a File** →
  pick `init_boot_a.bin` → it writes `magisk_patched-<random>.img` in Download →
  `adb pull` it to `.backups/nx1-<date>/init_boot_a.magisk.img` and record
  its sha256 in `PATCHED-INIT_BOOT.txt` (same layout the scripts expect).

## Unlock + root session (future — owner physically present)

`tools/unlock-flash.sh` encodes the full gated sequence; do not run it in the
bring-up run. What it will ask of the owner:

1. wipe consent — **approved by owner 2026-11-19, on record; not re-asked**
2. `adb reboot bootloader` → `fastboot flashing unlock` → **immediately press
   VOLUME UP** on the phone (quick press — NX1-verified gesture, not the
   generic AOSP vol-up-then-power flow) → device wipes, reboots. Without adb:
   physical early-boot menu (power off → hold POWER **then** VOL UP → 3-option
   menu → Vol-up navigates, Vol-down confirms → Fastboot)
3. post-wipe setup: skip the wizard, re-enable Developer options → USB
   debugging + OEM unlocking, accept the RSA prompt
4. second reboot to bootloader → unlock state verified → `fastboot flash
   init_boot magisk-patched-init_boot.img` → reboot
5. `tools/verify-root.sh` gates: boot completed, unlocked props, `su` uid 0,
   magisk binary, manager app, `/data/adb`

Bootloop safety: if boot doesn't complete in ~5 min, enter BROM and restore
`mtk w init_boot .backups/nx1-<date>/init_boot_a.bin` (a write session — only
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
- **Firmware payload** (sourced 2026-11-19, not downloaded — opportunistic extra):
  community MEGA folder https://mega.nz/folder/FH0FiAob#Z-KiYrb1o4CLwGq7SuGVIA
  (linked from bluefox-guide downgrade.html). 7z archives per model/region;
  this device is the **EEA** variant (product `BF001_EEA`, build
  `T69_S39_BLUEFOX_NX1_C1EEA_20260113`). Archives contain `super.img`,
  `vbmeta.img`, `boot.img` for fastboot-based restore (guide uses
  `fastboot flash super super.img` + vbmeta). Fetch with `megatools` (nixpkgs)
  if ever needed — our mtkclient backup already supersedes it for restore
  purposes (full per-partition images from the actual device).

## State log

| Date | State |
| --- | --- |
| 2026-11-19 | toolkit committed; backup read phase armed, waiting on owner BROM entry |
| 2026-11-19 | udev: owner placed `/etc/udev/rules.d/52-mtk.rules` manually (VID `0e8d` → MODE 0666 + uaccess; NX1 adb interface enumerates as `0e8d:201c`). No NixOS rebuild needed for this device — `programs.adb.enable` snippet above applies to standard Google-VID devices only |
| 2026-11-19 | **wipe consent: owner APPROVED** — phone contents disposable; the unlock-session runbook does not need to re-ask consent (unlock still needs owner physically present, volume-up confirm) |
| 2026-11-19 | target discipline: an unrelated device (Go103, Android 12) auto-connects to adb via mDNS/TCP on this network → all adb calls in `verify-root.sh` / `unlock-flash.sh` / `post-root-setup.sh` are pinned to `-s TLF2601S000307` (override with `NX1_SERIAL` env). fastboot is USB-only single-device; mtkclient targets BROM by VID |
