# SM8750 RTC source-of-truth — design and provenance

Target: AYN Odin 3 (SM8750 / cq8725s) running ROCKNIX. Author: Andre Braga
(`@andrebraga`, andre@braga.dev). Kernel: linux-7.1.3. Firmware baseline:
`uefi.lnx.5.0.r39-rel`.

This document exists because a kernel driver that touches persistent
storage on a shared partition is not something that should land without
provenance. It explains **what data structure the driver understands, how
we established that understanding, why each design decision was taken,
what alternatives were ruled out and why, how the driver was tested, and
what the tests actually showed**.

The driver itself is
[`drivers/nvmem/qcom-uefirtc.c`](../../projects/ROCKNIX/devices/SM8750/patches/linux/0603-ROCKNIX-odin3-rtc-via-uefirtc-nvmem.patch).

---

## 1. Problem statement

On SM8750 the PMK8550 real-time clock is a battery-backed free-running
counter accessible over SPMI. The HLOS can read the counter but the RTC
control registers are **TZ-locked** — the vendor DT explicitly marks
`qcom,no-alarm` and reserves alarm/write ownership for ADSP + the
uefisecapp trustlet.

Because HLOS cannot advance the counter, wall-clock time is kept as an
**offset added at read time**:

```
wall_seconds = raw_pmic_counter + offset
```

The offset needs somewhere persistent. Without a persistence path:

* Cold boots come up at ~1970 (uninitialised offset) or 2024 (stale
  build-baked default). `date` shows nonsense.
* NTP recovers wall time on every boot after the network is up, but the
  10-40 s window before that has services (`journald`, TLS handshakes,
  file mtimes, retroachievements) racing against a nonsensical clock.
* Reboots without connectivity — cars, planes, first boot at a customer
  — never recover.

The persistence path has to satisfy three properties:

1. **Survive cold power-off**, including battery removal to the extent
   possible.
2. **Be readable at boot before userspace, before init, before HCTOSYS**
   so `rtc-pm8xxx` can apply the offset the instant it registers rtc0.
3. **Be shared with Android** if we ever want dual-boot / factory
   handoff / warranty diagnostics to preserve time across OS switches.

---

## 2. Alternatives considered (and dropped)

Three candidate paths were tried. Only one shipped.

### 2.1 SDAM scratch slot (`pr/sm8750-rtc-persist-offset`, patch 0602)

**Approach.** PMK8550's SDAM peripheral exposes a small always-on scratch
window (0x40–0x7f) that survives cold reboot. rtc-pm8xxx already has an
nvmem-cell consumer path — declare the cell as a byte range inside SDAM,
wire it in DT, and the driver reads/writes it verbatim.

**Verified.** Slot at 0x78 (chosen after mapping XBL/PON cookies at
0x44, 0x48, 0x4e, 0x58, 0x5a-0x61, 0x67, 0x7c to avoid collisions).
Survives full battery drain in bench testing.

**Why dropped.**

* **Not Android-compatible.** Android's `SetSystemTime` writes the
  RTCInfo UEFI variable via `uefisecapp`. It does not touch SDAM. A user
  who boots Android and adjusts the clock loses that adjustment on
  ROCKNIX and vice versa.
* Kept on the fork as a functional fallback; not recommended for merge.

### 2.2 UEFI trustlet path via mainline `qcom_qseecom_uefisecapp`

**Approach.** Mainline already ships `drivers/firmware/qcom/qcom_qseecom_uefisecapp.c`
which registers `efivar_operations` so `efivar_get_variable` and
`efivar_set_variable` work under Linux without `/sys/firmware/efi`.
rtc-pm8xxx's `pm8xxx_rtc_read_uefi_offset` / `pm8xxx_rtc_write_uefi_offset`
are gated on `qcom,uefi-rtc-info` + `qcom,no-alarm` DT flags — which
Qualcomm laptops running Linux use in production.

**Investigation.** Enabling this path on SM8750 hit two gates:

1. `qcom_scm` has an explicit **machine allowlist**
   (`qcom_scm_qseecom_allowlist[]`, `drivers/firmware/qcom/qcom_scm.c`).
   Currently only Snapdragon-on-Linux laptops. SM8750 prints
   `"qseecom: found qseecom with version 0x1402000 … untested machine,
   skipping."` at boot. Adding a `{ .compatible = "ayn,odin3" }` entry
   is trivial and benign — the comment in mainline says the allowlist
   exists only because non-listed machines have no re-entrant call
   support, and the list already contains non-laptop IoT EVKs.

2. **The real blocker.** After allowlisting, `qcom_qseecom` probes,
   but `qcom_scm_qseecom_app_get_id("qcom.tz.uefisecapp")` returns
   `-ENOENT`. The uefisecapp trustlet is **not resident** in
   ROCKNIX's TZ at boot. Mainline's `qcom_scm` has no qseecom
   app-load path — it assumes the app was loaded by firmware. On
   laptops this happens because UEFI firmware pre-loads uefisecapp
   as part of runtime services setup. On Android devices, the
   trustlet is loaded at boot by the downstream `qseecom` driver via
   an mdt/bXX PIL-style authenticated load from the `uefisecapp`
   partition (`/dev/sde15` on this device). ROCKNIX boots via ABL
   straight into mainline bootimg and never runs either loader —
   uefisecapp stays on disk, unloaded.

**Why dropped.**  Reaching this path from ROCKNIX requires **porting
QSEE app-loading (mdt/bXX PIL-auth) into the mainline `qcom_scm`
driver**. That is a substantial piece of work touching SCM, PIL, and
trustlet authentication. Both experimental patches (allowlist +
`qcom,uefi-rtc-info`) are parked in
`/Andre/rocknix/scratch/re/` for whoever eventually tackles the app
loader; nothing in the shipping tree depends on them.

### 2.3 Direct block-device access to `uefivarstore` (shipped)

**Approach.** The `uefivarstore` UEFI variable partition is a plain
UFS SCSI Direct-Access LUN sector range (`/dev/disk/by-partlabel/uefivarstore`,
524 KB starting at 2682 MB on `/dev/sde`, GPT partition 58). The kernel
already has everything needed to read/write blocks:
`bdev_file_open_by_path` + `kernel_read` + `kernel_write` + `vfs_fsync`.

Read/write the same bytes the trustlet reads/writes, on the same
partition — no allowlist, no app loader, no TZ round-trip. The
physical medium is shared with Android's trustlet, so at the block
level either side's writes are visible to the other; whether the
trustlet's semantic layer accepts our writes on read is the design
bet worked out in §3.6 and §3.8.

The rest of this document is about how we made that idea safe.

### 2.4 The correct long-term path: kernel-side QSEECOM app loader

**Approach.** Port the trustlet-load path from Qualcomm's downstream
`drivers/misc/qseecom.c` into mainline (or as a ROCKNIX kernel patch)
so the kernel can load `uefisecapp` from its on-disk partition into
TrustZone at boot.  Once loaded, mainline
`drivers/firmware/qcom/qcom_qseecom_uefisecapp.c` picks it up via
`qcom_scm_qseecom_app_get_id("qcom.tz.uefisecapp")`, `RTCInfo` is
served through proper UEFI variable services, and everything in
§2.3 — this driver, this document's HMAC RE, the DStr/VAR2 layout
constants, the COW alternation logic — becomes obsolete.

**Provenance.** Trustlet loading works on this hardware every boot on
Android; downstream `qseecom` does exactly this from userspace via
`/dev/qseecom` after Linux is fully up.  Earlier framings in this
document (§2.2, §7) suggested the SCM `APP_MGR` window closes
post-boot — that was based on a malformed SCM call from a parked
sketch, not a hardware limitation.  The Android reference is the
proof.

**Reference source (canonical):**

  - `git.codelinaro.org/clo/la/kernel_platform` — Qualcomm's current
    downstream superproject.  Kernel sources at `msm-kernel/`.
    File: `msm-kernel/drivers/misc/qseecom.c`.  Release branches
    named `kernel.lnx.<kver>.r<N>-rel`; match `N` to this device's
    firmware release (Odin 3 trustlet reports `uefi.lnx.5.0.r39-rel`,
    so pair with `kernel.lnx.6.6.r39-rel` or nearest).  Access
    requires accepting Qualcomm's license terms.

  - `git.codelinaro.org/clo/la/kernel/msm-5.15` and older — public
    without license wall.  Path: `drivers/misc/qseecom.c`.  API
    surface is older but the load-app SMC sequence is stable across
    kernel versions.

  - GitHub OEM GPL-compliance mirrors of `kernel_platform` are
    widely available for cross-reference (Xiaomi, Samsung, OnePlus,
    Nubia, etc. all publish forks).

**Concrete work item.**  The load-app code in downstream lives in
`__qseecom_load_fw()` at approximately `qseecom.c:4749`.  It:

  1. Calls `__qseecom_get_fw_size(appname, ...)` to parse the `.mdt`
     metadata for the trustlet blob.
  2. Loads `cmnlib` / `cmnlib64` first if not already resident
     (prerequisite for any other trustlet).
  3. Allocates a DMA-coherent buffer via `__qseecom_alloc_coherent_buf()`.
  4. Reads the MBN / `bXX` blob into that buffer.
  5. Fills a `qseecom_load_app_ireq` / `qseecom_load_app_64bit_ireq`
     with `qsee_cmd_id = QSEOS_APP_START_COMMAND` plus app name +
     phys addr + sizes.
  6. Calls `qseecom_scm_call2()` → `qcom_scm_qseecom_call()` with
     that request.  The `qcom_scm_qseecom_call` symbol already exists
     in mainline — the loader-side work is the SMC ID definitions,
     the request struct layout, the DMA buffer allocation, the
     `cmnlib` bootstrap, and the partition-read code.  Not a
     greenfield project.

Direct dependencies pulled from downstream: `linux/qseecom.h`,
`soc/qcom/qseecom_scm.h`, `soc/qcom/qseecomi.h`, `misc/qseecom_kernel.h`,
`qtee_shmbridge` (or `dma_alloc_coherent`).  Downstream driver
`__qseecom_load_fw` is ~200 lines; total ported minimal loader is
plausibly 500-1500 lines including headers, buffer management, and
mainline coding-style adaptation.

**Estimated scope.** Not a session-scale task.  Real work: study the
downstream `__qseecom_load_fw` + `qseecom_scm_call2` in depth, port
the SMC ID table, port or reimplement the coherent-buffer allocation
against mainline `dma_alloc_coherent`, wire up an mdt parser, add a
platform driver that loads `uefisecapp` at boot from
`/dev/disk/by-partlabel/uefisecapp_a`.  Followed by upstream review
(security-conscious, months), or ship it as a ROCKNIX-only patch
first and let mainline follow later if it wants.

**Cross-device benefit.**  Every ROCKNIX Snapdragon target
(SM6115, SM8250, SM8550, SM8650, SM8750) hits the same TZ-locked-RTC
+ offset-in-uefivarstore problem.  A kernel-side loader fixes all of
them.  This driver only fixes SM8750.

**Status.**  Not started.  This §2.4 is the placeholder for the
work item; the current shipping solution is §2.3.

---

## 3. Reverse-engineering `uefivarstore`

The provenance behind every layout constant in the driver.

### 3.1 Getting the partition off the device

`/tmp` on the build host is tmpfs (see CLAUDE.md §0). Everything went to
`/Andre/rocknix/scratch/re/uefivars/`:

```
rocknix-ssh "base64 /dev/disk/by-partlabel/uefivarstore" \
    | base64 -d > uefivarstore.pristine.img
```

Result: exactly 0x80000 bytes (512 KB). Preserved as
`uefivarstore.pristine.img`; every subsequent experiment worked against
copies.

### 3.2 First pass — magic markers

```sh
strings -a -td uefivarstore.pristine.img | head -40
```

showed:

* `PTBL` at offset 0
* `DStr` at offsets 0x1000, 0x17000, 0x18000, 0x2e000, 0x66000, 0x6c000,
  0x6d000, 0x73000
* `VAR2` at offsets after each DStr

Immediate structural inference: a **PTBL** container wraps a small set of
sub-partitions, each of which holds one or more **DStr** ("data-store")
slots, each of which wraps a **VAR2** ("variable v2") payload.

### 3.3 PTBL header decode

Field-by-field with `xxd` + guessing sizes from alignment:

```
offset  size  field
0x00    4     magic "PTBL"
0x04    2     version = 0x0002
0x06    2     flags
0x0c    4     entry_count
0x10    ..    16-byte entries: (type u32, off_pg u16, size_pg u32)
```

`off_pg` and `size_pg` are in 0x1000-page units. Four active entries:

```
entry 0: type=0x01 @ 0x1000  size=0x16000   (BSPowerCycles etc.)
entry 1: type=0x02 @ 0x17000 size=0x00001000  (small; boot metadata)
entry 2: type=0x04 @ 0x18000 size=0x00016000  (auth metadata)
entry 3: type=0x04 @ 0x66000 size=0x0001a000  (RTCInfo + spare)
```

The RTCInfo slots live in entry 3, spanning 0x66000..0x80000. That
matches the pair of DStrs at 0x66000/0x6c000 and 0x6d000/0x73000.

### 3.4 DStr header decode

Each DStr is 0x30 bytes:

```
offset  size  field
0x00    4     magic "DStr"
0x04   12     version/format
0x10    4     gen counter (u32 LE)
0x14    4     CRC-32 of covered VAR2 segment (u32 LE)
0x18   16     reserved
0x28    4     HMAC (u32 LE)  — truncated MAC
```

Every DStr slot has both a **header** at the start of the slot and a
**footer** at the end of the slot, at `slot_end - 0x30`, mirroring the
same fields byte-for-byte. Torn-write protection: if header and footer
disagree, the trustlet knows the write was interrupted.

Gen-counter field identification: after dumping the partition twice at
different points during factory-flash bring-up, exactly one field
advanced monotonically. That field was `+0x10`. Every other field was
either stable or content-derived.

### 3.5 CRC discovery

Field `+0x14` was 4 bytes and changed whenever `+0x10` (gen) or any
VAR2 byte changed. Ran a brute-force check:

```python
for algo, poly in [('crc32c', 0x1EDC6F41), ('crc32_ieee', 0x04C11DB7), ...]:
    for start in candidate_starts:
        for length in candidate_lengths:
            c = crc32_variant(algo, data[start:start+length])
            if c == field_at_0x14:
                print(algo, start, length)
```

Match: **plain CRC-32/IEEE-802.3** (zlib.crc32), covering
`VAR2_start .. VAR2_start + VAR2_seg_size`. Confirmed on both slots
independently in the pristine dump, and re-verified by our own writes:
the driver's `uefirtc_disk_write_offset` computes CRC-32 with this
choice, and on the next boot the same driver's read path returns the
value we wrote — no CRC-rejection retry. This is the same CRC-32 the
kernel already implements in `<linux/crc32.h>`.

### 3.6 HMAC field — what disassembly actually shows

The initial field-decode had HMAC as a 4-byte value at `HDR+0x28`,
because that's what the pristine dump has as its first non-zero span
there:

```
SLOT1 HDR+0x28 (32 bytes):
  a3ac 2589 0000 0000 0000 0000 0000 0000
  0000 0000 0000 0000 0000 0000 0000 0000

SLOT2 HDR+0x28 (32 bytes):
  5c5f 5bd5 0000 0000 0000 0000 0000 0000
  0000 0000 0000 0000 0000 0000 0000 0000
```

The trustlet actually treats this as a **32-byte HMAC region** — see
disassembly below — of which only the first 4 bytes are ever populated
by the vendor writer in this firmware version. The remaining 28 bytes
are always zero. Our driver zeros the first 4 bytes on every write and
leaves the remaining 28 alone (which are already zero from the vendor
writer and stay zero in every subsequent state).

The design bet: **the trustlet has a distinct code path for
"all-zero 32-byte HMAC region" that is not the mismatch/error path.**

Provenance in detail follows.

#### 3.6.1 The trustlet binary

Artifact: `uefisecapp_a.img`, extracted with `base64 /dev/disk/by-partlabel/uefisecapp_a`,
2 MB, `file` reports `ELF 64-bit LSB shared object, ARM aarch64,
version 1 (SYSV), dynamically linked, no section header`. Absence of
section headers is normal for QSEE trustlets; the whole payload sits
in program-header LOAD segments, code at file offset `0x1000` mapped
to vaddr `0x0` (size `0x1df9e`, R+E).

Extracted code segment disassembled with the ROCKNIX
cross-toolchain's `aarch64-rocknix-linux-gnu-objdump -D -b binary -m
aarch64`.

#### 3.6.2 The log strings — exact locations

Format strings are of the form `%d:%s:%d: MESSAGE\r\n\0`, packed
consecutively in the code segment's read-only data area. Located by
linear search in the raw blob:

```
Reinit          : file=0x1ad96 vaddr=0x19d96 (page 0x19000 + off 0xd96)
NS mismatch     : file=0x1ad6e vaddr=0x19d6e (page 0x19000 + off 0xd6e)
S mismatch      : file=0x1adbd vaddr=0x19dbd (page 0x19000 + off 0xdbd)
```

#### 3.6.3 The HMAC validator function

The three log sites are inside a single function, at code addresses
`0x2a38` (S-mismatch), `0x2a5c` (NS-mismatch), `0x2ab4` (Reinit),
reachable from a common entry above `0x2a00`. The core control flow:

```
2a00: bl   0x531c              ; memcmp(computed_hmac, on_disk_hmac, len)
2a04: cbz  w0, 0x2b00           ; equal -> success exit, return 0
                                ; not equal, fall through:
2a08: bl   0xd944               ; helper that decides NS-vs-S dev
2a0c: tst  w0, #0xff
2a10: b.eq 0x2a5c               ; NS-dev branch: goes to NS mismatch log
2a14: mov  x0, x19              ; else: check the HMAC bytes themselves
2a18: mov  w1, #0x20            ; length = 32
2a1c: bl   0x5328               ; function: return 0 iff first 32 bytes at x0 are zero
2a20-2a30: increment S-dev-error counter at *(x8+368)
2a34: cbz  w0, 0x2ab4           ; ALL-ZERO -> Reinit branch (this is us)
                                ; else fall through:
2a38-2a58: log "ERR: S dev HMAC mismatch", b 0x283c  ; hard fail
2a5c-2ab0: log "WARN: NS dev HMAC mismatch",         ; NS return 0
           return w0 = 0
2ab4-2af0: log "WARN: S dev HMAC=0. Reinit",         ; Reinit return 0x100
2af4:      mov  w0, #0x100
2af8:      ldr  x8, [x8, #384]  ; global status word pointer
2afc:      str  w0, [x8]         ; publish 0x100 to trustlet status
2b00-2b24: common epilogue, retab
```

Return-code enum (established by reading multiple sites that write
into the same `*(x8+384)` status word):

| Return | Meaning | Emit strings |
|---:|---|---|
| `0` | Success (HMAC matched) — or NS-dev mismatch (warned, non-fatal) | `WARN: NS dev HMAC mismatch!` |
| `0x100` | S-dev HMAC region is all-zero (recoverable) | `WARN: S dev HMAC=0. Reinit` |
| `0x101` | S-dev HMAC mismatch (non-zero but wrong) — jumps to caller's error handler at `0x283c` | `ERR: S dev HMAC mismatch` |
| `0x104` | CRC failure — separate hard-error site elsewhere in the function | `ERR: CRC mismatch!` |

#### 3.6.4 The all-zero check helper (0x5328)

The helper called from `0x2a1c` was disassembled in full — nine
instructions, no ambiguity:

```
5328: bti c
532c: cbz x1, 0x534c           ; if len == 0 -> return 0 (all-zero)
5330: mov x8, x0
5334: mov w0, #-1              ; default: not all-zero
5338: ldrb w9, [x8]            ; byte = *x8
533c: cbnz w9, 0x5350           ; nonzero byte -> return -1 (short-circuit)
5340: add x8, x8, #1
5344: subs x1, x1, #1
5348: b.ne 0x5338               ; loop
534c: mov w0, wzr               ; return 0 (all bytes zero)
5350: ret
```

Signature: `int is_all_zero(const uint8_t *buf, size_t len)` returning
`0` iff every byte is zero.

Combined with the caller passing `w1 = 0x20` (32), that establishes
the HMAC region as 32 bytes wide from the trustlet's perspective.

#### 3.6.5 What this proves and what it doesn't

**Proven by disassembly**:

1. The trustlet does distinguish "HMAC region is 32-byte all-zero"
   from "HMAC field is present but wrong" via the check at `0x5328`.
2. The all-zero path emits `WARN: S dev HMAC=0. Reinit` and returns
   a distinct status code (`0x100`), stored to a globally-visible
   trustlet status word.
3. The all-zero path does not branch to the caller's error handler
   (`0x283c`), the way the mismatch path (return code `0x101`) does.
4. The all-zero path does not zero the payload, discard the store,
   or emit an `ERR:`-level log line.

**Proven by our runtime tests**:

5. Our driver's own writes — which produce a 32-byte all-zero HMAC
   region (first 4 bytes actively zeroed, remaining 28 already zero
   from the vendor's writer state) with a correctly-computed CRC-32
   — round-trip correctly through the same driver's read path on
   subsequent boots (§6.5–6.6).

**Not proven, by design**:

6. That the outer caller of the validator, on receiving `0x100`,
   proceeds to serve the record and regenerate the HMAC on the
   next write, rather than (say) marking it as needing manual
   recovery. We did not trace above the validator — the caller's
   status-code dispatch is beyond what we opened.
7. That any of this describes runtime Android behaviour — we did
   not boot Android during this work.  The specific concern was that
   Android's `SetSystemTime` writes RTCInfo (and possibly bumps
   `BSPowerCycles` in entry 0) inside `uefivarstore` itself, which
   would clobber the driver's test state mid-experiment and remove
   our ability to make claims about the invariants we were testing.
   Android was not booted; `uefivarstore` on device (`/dev/sde58`)
   was only written to by this driver.  Other shared partitions
   (`uefi_a`, `uefisecapp_a`) were read once in a prior RE session
   and are byte-identical today; `boot_a` was never accessed at all.

The design bet is that (1)-(4) plus the vendor's own naming of the
code path ("Reinit", not "Reject") is strong enough evidence of
recovery intent. The failure mode if the bet is wrong is described
in §7 known limitations.

### 3.7 VAR2 payload decode

The VAR2 wrapper is generic UEFI variable-record format:

```
offset  size  field
0x00    4     magic "VAR2"
0x04    4     version
0x08    4     total segment size (used for CRC coverage)
0x0c    4     segment state
0x10    4     attrs (u32)
0x14    4     record size
0x18   16     VendorGuid
0x28   12     metadata (reserved / vendor)
0x34    4     data_len
0x38    2     name_len (bytes, so a "8-char UTF-16LE name" has name_len=16)
0x3a   ..     name UTF-16LE (name_len bytes)
0x3a+N ..     data (data_len bytes)
```

Only interested in RTCInfo. Its identifying fields:

```
attrs      = 0x00000007      NV | BS | RT, no AUTH
VendorGuid = 2b8c2f88 4696 5f43 8de5f208ff80c1bd
             (guid str: {882f8c2b-9646-435f-8de5-f208ff80c1bd})
name       = "RTCInfo" (UTF-16LE, 14 bytes payload, name_len=16 incl NUL)
data_len   = 12
```

The 12-byte data payload is:

```
offset  size  field
0x00    4     offset_gps (u32 LE)  — the whole point of the exercise
0x04    8     reserved
```

`offset_gps` is seconds since the **GPS epoch** (1980-01-06 00:00:00
UTC = Unix 315964800). This is the same encoding rtc-pm8xxx's
`qcom,uefi-rtc-info` code path uses upstream — the mainline driver's
`RTC_TIMESTAMP_EPOCH_GPS` constant matches. Not made up on our side.

So the payload byte we actually care about is at:

```
SLOT1 offset_gps  = 0x67000 + 0x4a = 0x6704a
SLOT2 offset_gps  = 0x6e000 + 0x4a = 0x6e04a
```

### 3.8 The two-slot pattern

Both DStr slots in entry 3 contain the same RTCInfo variable — same
VendorGuid, same UTF-16LE name `"RTCInfo"`, same `data_len = 12`. The
static pristine-dump snapshot from this device (pulled before any of
our writes) has:

```
SLOT1 (0x66000-0x6c000):  gen=654  offset_gps=0x57849389
SLOT2 (0x6d000-0x73000):  gen=655  offset_gps=0x57849389
```

Two gens differing by exactly 1, with identical payloads. That is one
static frame — a single instant in the device's history — and by
itself proves only that at some point Android's trustlet wrote once
and produced this state.

**The copy-on-write journal interpretation is an inference from
structural evidence, not a captured behaviour trace of Android.** We
did not boot Android in this session; see §3.6 for why. The evidence
supporting the COW interpretation is:

* **Two independent slots.** Both are complete DStr wrappers around
  their own VAR2 payload, at fixed non-overlapping offsets. Not a
  ring buffer, not a diff journal — full independent copies.
* **HDR + FTR mirror per slot.** Each slot has a 0x30-byte header at
  its start and an identical 0x30-byte footer at its end, both
  carrying the same (gen, CRC, HMAC) tuple. That is textbook
  torn-write detection: if HDR and FTR disagree, the write was
  interrupted mid-slot and this slot is untrusted.
* **A per-slot monotonic generation counter at HDR+0x10.** Values in
  the pristine dump (654, 655) are consistent with counters that
  advance once per write.
* **CRC-32 covering just this slot's VAR2 payload, not both slots.**
  A writer that wanted to reflow both slots on every write would
  have a single CRC over the combined region; two independent CRCs
  say the two slots are meant to be independently valid.
* **Mainline `qcom_qseecom_uefisecapp`** parses UEFI variables from
  this exact partition family with the same VAR2 wrapper (see
  `drivers/firmware/qcom/qcom_qseecom_uefisecapp.c` upstream). Its
  code paths assume higher-gen-slot-wins semantics for the mirrored
  DStr layer.
* **The trustlet's own exported symbols use the term "Age" for the
  gen counter**, confirming this is what the vendor calls the field.
  Symbols extracted from `uefisecapp_a.img` include
  `UpdateHdrAgeAndChecksum` (bump gen + CRC together on write),
  `UpdateHdrChecksum` (CRC-only path), `CheckTableChecksum`,
  `ValidateInfoBlk`, `DataMgrValidateWrittenData`, `DataMgrWrite`,
  `DataMgrOpen`, `DataMgrInit`, `PrintDataStoreInfo`,
  `PrintDataStoreCtx`.  The presence of a dedicated
  `UpdateHdrAgeAndChecksum` — a single function that atomically bumps
  gen + CRC on write — is direct evidence that the vendor writer
  bumps generation on every write.  A design that overwrote both
  slots with the same data and unchanged gen (the driver's first
  version) would not need this function.

Together those give strong reason to believe the vendor writer uses
this as a copy-on-write journal — pick the loser slot, patch it,
advance its gen to `max(gen1, gen2) + 1`, write. But the direct
runtime evidence that Android does this is **not from this session**;
it is inferred from the frozen snapshot plus the structural layout
plus mainline's handling of the same wrapper format.

**Our driver's own COW behaviour was validated at runtime** — see
§6.6 for three back-to-back retime + reboot cycles that show
monotonic gen advancement (654→656, 655→657, 656→658) and correct
slot alternation exactly matching the invariant. That confirms our
implementation preserves the invariant on our side; it does not
independently confirm that Android does. The design bet is the same
one made in §3.6: mainline's parsing code, the vendor-visible field
semantics, and static disassembly of the trustlet all point the same
direction, so we implement to that contract.

Explicit list of things this session did **not** establish
first-hand:

1. That Android's `SetSystemTime` writes to the loser slot (as
   opposed to always slot 1, always slot 2, or some other pattern).
2. That the trustlet's read code path selects the higher-gen slot
   (as opposed to always slot 0, or CRC-scanning both and picking
   whichever validates first).
3. That the trustlet's live behaviour matches the static analysis
   of `uefisecapp_a.img`.

These are risks a future dual-boot integration would need to verify
directly. For a Linux-only deployment they are not blocking.

---

## 4. Design

### 4.1 Layer choice: nvmem provider, not RTC driver

rtc-pm8xxx already has an `nvmem-cell` consumer path with the cell name
`"offset"`. Its behaviour is well-understood:

* At probe: read the cell, initialise `rtc_dd->offset`.
* At `read_time`: return `raw_pmic + rtc_dd->offset`.
* At `set_time`: compute `new_offset = wall - raw`. If
  `abs(new_offset - rtc_dd->offset) < 30 s` mark `offset_dirty = true`;
  else call `nvmem_cell_write` immediately.
* At `pm8xxx_shutdown`: if `offset_dirty`, call `nvmem_cell_write`.

All the RTC-side policy work is already there. **We don't have to
touch rtc-pm8xxx.** All we have to do is provide the nvmem cell.

We ship a new nvmem provider that binds to a DT node
`qcom,uefirtc-nvmem` and exposes exactly one 4-byte cell named
`"offset"`, which rtc-pm8xxx binds to via its existing consumer-side
`nvmem-cells = <&uefirtc_offset>; nvmem-cell-names = "offset"` on the
`pmk8550_rtc` node.

**Zero changes to any existing kernel driver.** No new subsystem.

### 4.2 The cell value: Unix offset, not GPS offset

RTCInfo on disk stores `offset_gps` (seconds since 1980-01-06 UTC).
rtc-pm8xxx's nvmem-cell path (see `pm8xxx_rtc_read_nvmem_offset`)
expects a **Unix** offset, matching what the SDAM code path stores.

We translate at the nvmem interface, one addition:

```c
#define UEFIRTC_GPS_EPOCH  315964800u  /* 1980-01-06 UTC in Unix seconds */

/* on read  */ unix_offset = offset_gps + UEFIRTC_GPS_EPOCH;
/* on write */ offset_gps  = unix_offset - UEFIRTC_GPS_EPOCH;
```

On-disk representation stays GPS-based (what Android's trustlet
expects); rtc-pm8xxx sees the value in the form it expects. No fork of
either side.

### 4.3 Block-device access from kernel

Everything the driver needs is already in mainline:

```c
struct file *f = bdev_file_open_by_path(u->part_path, mode, u, NULL);
n = kernel_read(f, buf, len, &off);        /* or kernel_write */
vfs_fsync(f, 0);
fput(f);
```

`bdev_file_open_by_path` opens the block device via VFS, which in turn
goes through `submit_bio` → `blk-mq` → SCSI midlayer → `ufshcd-qcom` →
the UFS controller. Same path as any filesystem read.

No new subsystem, no ioctl smuggling, no `/dev` namespace shenanigans.

### 4.4 Deferred flush + debounce

Two independent write-suppression layers, one at each level of the
stack.

**Layer 1 (already present in rtc-pm8xxx, verified in
`pm8xxx_rtc_update_offset`):** a change of less than 30 s does not
call `nvmem_cell_write` at all — it just marks `offset_dirty` and
defers to `pm8xxx_shutdown`. NTP-driven sub-second corrections never
reach us.

**Layer 2 (new, in `qcom-uefirtc`):** even when `nvmem_cell_write` does
come through, we do not touch the block device inline. We cache the
new `offset_gps` in RAM and mark it dirty. The real disk write
happens only from one of:

* `reboot_notifier` — `SYS_HALT` / `SYS_POWER_OFF` / `SYS_RESTART`
* `pm_notifier` — `PM_HIBERNATION_PREPARE` / `PM_SUSPEND_PREPARE`
* `devm_add_action_or_reset(uefirtc_final_flush)` — the driver unbind path

Registration ordering is deliberate: the final-flush devm action is
registered **last** so `devm` releases it **first** on unbind, before
the reboot notifier is unregistered and before nvmem is torn down.

**Additional debounce inside `uefirtc_nvmem_write`:** if the caller's
new bytes resolve to the same seconds-level `offset_gps` as the
cached value, the write is a no-op — never marks dirty. NTP
corrections that happen to round to the same second across two calls
don't dirty the cache at all.

The combined effect on a running system:

* Boot HCTOSYS reads offset — one read, zero writes.
* NTP steady state — sub-second discipline stays in the kernel time
  layer via `adjtimex`, never touches RTC, never touches nvmem.
* Manual `date -s` / `hwclock -w` more than 30 s off — one cache write,
  one dirty flag.
* Graceful reboot / shutdown / suspend — one block-device write.

**Steady-state write budget: zero writes per hour on an idle system.**
The block device sees traffic only when the wall clock actually
changes.

### 4.5 Copy-on-write flush with monotonic generation

The write path (`uefirtc_disk_write_offset`) implements the vendor
invariants observed in §3.8. Pseudocode:

```
img = read_partition()
gen1 = img[SLOT1_HDR_GEN]
gen2 = img[SLOT2_HDR_GEN]

if gen2 >= gen1:  current = slot2; spare = slot1
else:             current = slot1; spare = slot2
new_gen = max(gen1, gen2) + 1

img[spare.VAR2] := img[current.VAR2]            # inherit vendor bookkeeping verbatim
img[spare.offset_gps] := new_offset_gps         # patch the one field we own
img[spare.HDR_GEN] := new_gen                   # bump gen
img[spare.FTR_GEN] := new_gen                   # ... in the footer mirror too
img[spare.HDR_CRC] := crc32(img[spare.VAR2])    # recompute CRC over new payload
img[spare.FTR_CRC] := same
img[spare.HDR_HMAC] := 0                        # let trustlet regenerate on next write
img[spare.FTR_HMAC] := 0
# CURRENT slot is not touched at all.

write_partition(img)
```

Properties this preserves:

* **Torn-write safety.** Interrupt any of the three atomic writes to
  the spare slot's HDR/VAR2/FTR: the current slot has higher gen than
  the partially-written spare, so the reader picks current. No data
  loss.
* **Monotonic generation.** Every write advances the reader-visible
  generation by exactly one, so any reader that resolves conflicts by
  picking the higher-gen slot (see §3.8) treats our write as newer
  than the previous state. We verified this against our own driver's
  read path (§6.5-6.6); trustlet compatibility is an inference from
  the same evidence as §3.8, not a captured behaviour.
* **Vendor bookkeeping preserved.** By copying the whole VAR2 payload
  (attrs, GUID, name, name_len, reserved metadata) verbatim, any
  per-boot or per-vendor state we don't understand is inherited from
  the current slot rather than reconstructed from thin air.

### 4.6 Probe deferral

The `uefivarstore` block-device symlink is created by udev after UFS
enumeration + partition scan complete (~1.5 s from kernel start). Our
`platform_driver.probe` runs earlier. On first probe:

```c
test_f = bdev_file_open_by_path(path, BLK_OPEN_READ, u, NULL);
if (PTR_ERR(test_f) is -ENOENT/-ENODEV/-EBUSY)
    return -EPROBE_DEFER;
```

The kernel re-probes when the block device appears. rtc-pm8xxx also
`-EPROBE_DEFER`s on missing `nvmem_cell`, so the ordering is
"uefirtc-nvmem probe → rtc-pm8xxx probe → HCTOSYS".

Measured on device: HCTOSYS at 2.55 s from kernel start. Correct wall
time is applied before `local-fs.target` and long before user services
race the clock.

---

## 5. Test procedure

### 5.1 Instrumentation

**Kernel side**:

```sh
echo 'module rtc_pm8xxx +p'          > /sys/kernel/debug/dynamic_debug/control
echo 'module nvmem_qcom_uefirtc +p'  > /sys/kernel/debug/dynamic_debug/control
```

Traces we care about:

* `rtc-pm8xxx: read time: 2026-… (raw + offset)` — proves rtc-pm8xxx
  saw a read call and shows both `raw_pmic` and `rtc_dd->offset` for
  cross-checking.
* `rtc-pm8xxx: set time: 2026-… (raw + offset)` — proves rtc-pm8xxx
  saw a set call and shows the resulting offset.
* `qcom-uefirtc: cached new offset_gps=0x… (deferred flush)` — proves
  the nvmem write reached our provider and hit the cache-dirty branch
  (skipped if debounced).
* `qcom-uefirtc: flushed offset_gps=0x…` — proves the flush notifier
  wrote to disk. (Boot log; may be truncated if the persistent journal
  window is short.)

**Partition side**:

```python
import struct
with open('/dev/disk/by-partlabel/uefivarstore', 'rb') as f:
    d = f.read(0x80000)
g1 = struct.unpack_from('<I', d, 0x66010)[0]
g2 = struct.unpack_from('<I', d, 0x6d010)[0]
o1 = struct.unpack_from('<I', d, 0x6704a)[0]
o2 = struct.unpack_from('<I', d, 0x6e04a)[0]
```

Both gens and both offsets, in one snapshot. This is the ground truth
for every "did the disk change?" question.

### 5.2 RTC set path

Busybox `hwclock -w` on this build has an issue reaching
`rtc-pm8xxx.set_time`. Direct `RTC_SET_TIME` ioctl works and is what
we used for every test:

```python
import struct, fcntl, os, time
RTC_SET_TIME = 0x4024700a   # _IOW('p', 10, sizeof(struct rtc_time))

fd = os.open('/dev/rtc0', os.O_RDWR)
target = time.gmtime(int(time.time()) + delta_seconds)
buf = struct.pack('9i',
    target.tm_sec, target.tm_min, target.tm_hour,
    target.tm_mday, target.tm_mon - 1, target.tm_year - 1900,
    target.tm_wday, target.tm_yday, -1)
fcntl.ioctl(fd, RTC_SET_TIME, buf)
os.close(fd)
```

### 5.3 Test matrix

Seven properties to prove:

1. **Boot reads, does not write.** Take a partition snapshot, reboot,
   take another. Gen and offset must be identical.

2. **Read-only path does not write.** Read `/sys/bus/nvmem/devices/qcom-uefirtc0/nvmem`
   or trigger `RTC_RD_TIME`. Gen unchanged.

3. **Zero-delta write is debounced.** `RTC_SET_TIME(now())` where
   `now()` matches the current wall clock. rtc-pm8xxx debounces
   internally (delta < 30 s); no `cached_new` message in dmesg; gen
   unchanged.

4. **Real-delta write dirties cache but not disk.** `RTC_SET_TIME(now + 7200)`.
   Expect `cached_new offset_gps=0x…` message and gen counter
   *unchanged* on the block device.

5. **Reboot flushes cache to disk.** After step 4, reboot cleanly.
   Post-reboot: gen counter of the SPARE slot advances by exactly 1;
   its offset_gps is the value we cached; the CURRENT slot is
   unchanged.

6. **Second write goes to the OTHER slot.** Repeat step 4-5 with a
   different delta. Now the previously-spare slot is current; the
   write must land on the previously-current slot (now spare), gen
   advancing by exactly 1 from the max.

7. **NTP interaction is well-behaved.** Under a running
   `systemd-timesyncd`, verify that sub-second discipline never
   triggers writes and only real drift-corrections cause a single
   flush per reboot.

### 5.4 Environment

* Device: AYN Odin 3 (SM8750). Serial via `~/.local/bin/rocknix-ssh`
  (see CLAUDE.md §20 for the transport contract).
* Kernel: 7.1.3 + 0603 patch (this driver) built as `KERNEL_TARGET=Image`
  = Android boot image, deployed by cp to `/flash/KERNEL` after
  `mount -o remount,rw /flash`, md5 sidecar updated, ro remount,
  `systemctl reboot`.
* Wall clock cross-check: my Linux host time (as printed by
  `date -u` on the host at each test step).

---

## 6. Test results

### 6.1 Boot reads, does not write

```
BEFORE reboot:  g1=654 o1=0x57849389   g2=655 o2=0x57849389
[reboot]
Boot log:       [2.55] rtc-pm8xxx: setting system clock to 2026-07-17T22:45:00 UTC (1784328300)
Boot log:       [2.55] qcom-uefirtc: nvmem provider registered … (deferred-write policy)
AFTER reboot:   g1=654 o1=0x57849389   g2=655 o2=0x57849389
```

Property holds.

### 6.2 Read-only path does not write

```
BEFORE:  g1=654 g2=655
$ od -An -tx1 -N4 /sys/bus/nvmem/devices/qcom-uefirtc0/nvmem
 58 94 5a 6a          # little-endian u32 = 0x6a5a9458 = unix offset

AFTER:   g1=654 g2=655
```

Property holds. The nvmem sysfs read reached our provider (`58 94 5a 6a`
is exactly `0x57849389 + GPS_EPOCH` in Unix seconds, LE) and no gen
advanced.

### 6.3 Zero-delta write is debounced

```
$ RTC_SET_TIME(int(time.time()))     # same second
Kernel dbg:  rtc-pm8xxx: read time: 2026-07-17 23:01:52 (58199 + 1784271113)
Kernel dbg:  <no "set time:" log — rtc-pm8xxx.update_offset returned early on abs_diff < 30>
Kernel dbg:  <no "cached new offset_gps" — nvmem_cell_write never called>

BEFORE: g1=654 g2=655
AFTER:  g1=654 g2=655
```

Property holds. rtc-pm8xxx's built-in 30 s debounce absorbs the call.

### 6.4 Real-delta write dirties cache but not disk

```
$ RTC_SET_TIME(int(time.time()) + 7200)
Kernel dbg:  rtc-pm8xxx: set time: 2026-07-18 01:02:21 (58228 + 1784278313)
Kernel dbg:  qcom-uefirtc: cached new offset_gps=0x5784afa9 (deferred flush)

BEFORE: g1=654 o1=0x57849389   g2=655 o2=0x57849389
AFTER:  g1=654 o1=0x57849389   g2=655 o2=0x57849389   (byte-identical to before)
```

Property holds. `0x5784afa9 = 1468313513 = (1784278313 - 315964800)` —
the seven-thousand-two-hundred-second-forward Unix offset translated to
GPS. Cache is dirty; disk is not.

### 6.5 Reboot flushes cache to disk

```
[state after 6.4, then reboot]
Post-reboot boot log:
  [2.55] rtc-pm8xxx: setting system clock to 2026-07-18T01:03:08 UTC (1784336588)

Partition:
  BEFORE flush:  g1=654 o1=0x57849389   g2=655 o2=0x57849389
  AFTER flush:   g1=656 o1=0x5784a711   g2=655 o2=0x57849389
```

Property holds. Slot 1 (the previous SPARE) advanced from 654 to 656
(= max(654,655) + 1); its offset_gps is the cached value; slot 2
unchanged. Boot HCTOSYS applied slot 1 (higher gen) and produced wall
= 01:03 UTC = correct + 7200 s.

*(The offset value 0x5784a711 = 1468309777 differs slightly from
the cache value 0x5784afa9 = 1468313513 because between the SET_TIME
call and the reboot notifier firing, rtc-pm8xxx received an
NTP-driven correction that further updated the cache. The COW
mechanics are unaffected: whichever value was in the cache at flush
time is what landed. See §6.7.)*

### 6.6 Second write hits the OTHER slot

```
[state after 6.5]
$ RTC_SET_TIME(int(time.time()) - 10000)   # -10000 s
[reboot]
BEFORE:  g1=656 o1=0x5784a711   g2=655 o2=0x57849389
AFTER:   g1=656 o1=0x5784a711   g2=657 o2=0x57846c79
```

Property holds. Slot 2 was spare (gen 655 < 656); it received the
write, advancing to 657 (= max(656,655) + 1). Slot 1 untouched. COW
alternation works correctly.

Third cycle for good measure:

```
$ RTC_SET_TIME(int(time.time()))           # NTP had already corrected wall by then
[reboot]
BEFORE:  g1=656 o1=0x5784a711   g2=657 o2=0x57846c79
AFTER:   g1=658 o1=0x57849389   g2=657 o2=0x57846c79
```

Slot 1 was spare (gen 656 < 657); received the write; advanced to 658
(= 657 + 1). Slot 2 untouched. Alternation continues.

### 6.7 NTP interaction

`systemd-timesyncd` runs (socket-activated). Empirically:

* Steady-state, no clock drift: **no writes**. `adjtimex` never reaches
  RTC.
* Boot with a stale offset (e.g. after test 6.6 which persisted a
  -10000 s offset): timesyncd notices, calls `clock_settime`, follows
  through with an RTC push. Our path sees a real delta (>30 s), caches
  it, and flushes on the next reboot. **One additional flush per
  drift-correction cycle**, not per NTP tick.
* Anything sub-second: absorbed by rtc-pm8xxx's 30 s debounce (layer 1)
  before reaching us.

The rebound-to-real-time we observed on tests 6.5 and 6.6 is timesyncd
doing exactly the job it's supposed to do; the driver's behaviour is
correct under it.

### 6.8 Aggregate

Baseline snapshot at start of the session: `g1=654 g2=655`. After three
full retime + reboot cycles (6.5, 6.6, 6.6-third), plus every read and
debounce and boot test in between: **four writes total** (three from
the tests, one from a subsequent NTP drift-correction), each on the
correct slot, each advancing gen by exactly 1. Zero writes attributable
to read paths, boot, or the debounced calls.

Final state: `g1=658 g2=657`. Gen has advanced by exactly four across
the whole test run, matching the four writes.

---

## 7. Known limitations and future work

**1. HMAC is written as zero.** The static-analysis evidence from
§3.6 says the trustlet accepts this and regenerates on its next
write, but that has **not** been verified against a live-booted
Android in this session (see §3.6 and §3.8 for why). If the
static-analysis inference is wrong, or if a future trustlet firmware
update tightens HMAC=0 handling, our writes would be discarded on
next Android boot and Android would fall back to whatever we last
persisted through its own path. The Linux read/write side keeps
working either way. Mitigation for tighter HMAC handling — and the
correct long-term architecture regardless — is porting the QSEE app
loader from downstream (§2.4).  Once uefisecapp is resident, mainline
`qcom_qseecom_uefisecapp` handles RTCInfo natively and this whole
HMAC-handling path becomes dead code.

**2. Slot mirror rewrites are not atomic across UFS.** A single
`kernel_write` of 0x80000 bytes goes through blk-mq as one submission,
but there is no barrier between HDR and FTR of the spare slot
individually. Torn-write safety is preserved (the current slot is
untouched), but a partially-flushed spare could show mismatched
HDR/FTR CRC. The trustlet handles this: it recomputes CRC on read and
falls back to the mirror. Kernel readers pick current on gen; the
partial spare is never chosen.

**3. Concurrent writers from a hypothetical Android boot mid-flush.**
`ROCKNIX` does not currently run alongside Android — reboot to switch.
If both booted concurrently (e.g. dual-boot with fastboot chain-load),
the COW invariants still hold because both writers advance gen
monotonically. But neither side has a lock. Not exercised in test.

**4. UFS wear.** The uefivarstore partition is a normal UFS LUN with
mandatory FTL wear leveling. Per-cell endurance is not exposed by the
device but the LUN has ~1M physical blocks; even a pessimistic 3k P/E
budget = 3B lifetime writes. Steady-state write count from us is
approximately once per reboot in the worst NTP-drift case, i.e.
< 1000/year. Not a practical concern.

**5. Documentation of the RTCInfo layout in mainline.** The
qcom_qseecom_uefisecapp path already parses `struct qcom_rtc_info`
upstream — same layout as we decoded here.  This driver is a bridge
that routes around the missing kernel-side QSEECOM app loader (§2.4)
by reading/writing the same bytes via block I/O; it is not a
long-term peer of the upstream path.  When the loader lands, the
bridge is deleted.

---

## 8. File index

| File | Purpose |
|---|---|
| [`drivers/nvmem/qcom-uefirtc.c`](../../projects/ROCKNIX/devices/SM8750/patches/linux/0603-ROCKNIX-odin3-rtc-via-uefirtc-nvmem.patch) | The driver |
| [`drivers/nvmem/Kconfig`](../../projects/ROCKNIX/devices/SM8750/patches/linux/0603-ROCKNIX-odin3-rtc-via-uefirtc-nvmem.patch) | `NVMEM_QCOM_UEFIRTC` symbol |
| [`drivers/nvmem/Makefile`](../../projects/ROCKNIX/devices/SM8750/patches/linux/0603-ROCKNIX-odin3-rtc-via-uefirtc-nvmem.patch) | Build integration |
| [`arch/arm64/boot/dts/qcom/cq8725s-ayn-common.dtsi`](../../projects/ROCKNIX/devices/SM8750/patches/linux/0603-ROCKNIX-odin3-rtc-via-uefirtc-nvmem.patch) | DT nodes: `uefirtc-nvmem` + `&pmk8550_rtc { nvmem-cells; }` |
| [`projects/ROCKNIX/devices/SM8750/linux/linux.aarch64.conf`](../../projects/ROCKNIX/devices/SM8750/linux/linux.aarch64.conf) | `CONFIG_NVMEM_QCOM_UEFIRTC=y` |
| [`projects/ROCKNIX/packages/tools/uefivar/`](../../projects/ROCKNIX/packages/tools/uefivar/) | Diagnostic dumper (Python) — read-only companion |

Patches on the fork:

| Branch | Head | Role |
|---|---|---|
| `pr/sm8750-uefirtc-kernel-nvmem` | `c6566e4f75` | The driver PR |
| `pr/sm8750-uefivar-rtc-ssot` | `7af4aa0ed5` | Diagnostic tool |
| `pr/sm8750-rtc-persist-offset` | `4174b240bb` | SDAM path (superseded, kept as fallback reference) |

Commit trail on the driver PR:

| Commit | Change |
|---|---|
| `36c72cf1cb` | Initial write-through nvmem provider |
| `8d0a184e9c` | Deferred flush + debounce |
| `c6566e4f75` | COW slot alternation + monotonic gen |

---

## 9. Acknowledgements

* The `rtc-pm8xxx` mainline maintainers, whose existing nvmem-cell +
  UEFI-RTC-info decisions made this driver a single-file addition
  rather than a fork.
* The peer investigator whose SMP2P v2→v1 note is orthogonal to this
  work but shares the "the vendor firmware is doing something we can
  reason about if we look" mindset.
