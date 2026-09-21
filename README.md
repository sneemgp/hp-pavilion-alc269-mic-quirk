# HP Pavilion 15 (103c:2164): missing internal-microphone boost limit

A one-line Linux kernel quirk for the HP Pavilion 15 Notebook PC (2014, Haswell-ULT) whose Realtek
**ALC3227** codec exposes the full **36 dB** internal-microphone boost range on top of the +30 dB ADC
capture gain. The kernel already has the fixup for this defect class; this machine's subsystem ID is
simply not in the table that selects it.

```c
SND_PCI_QUIRK(0x103c, 0x2164, "HP Pavilion 15 Notebook PC", ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED),
```

Added to `alc269_fixup_tbl[]` in `sound/hda/codecs/realtek/alc269.c`, sorted among the neighbouring
`0x103c` entries. That is the entire change: one line, no new enum, no new function.

## Why this fixup

`ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED` already exists and is exactly the combination this machine
needs: it runs `alc269_fixup_limit_int_mic_boost()` (clamping the internal mic pin's amp-in caps to two
positions, 0 or 12 dB) and chains to `ALC269_FIXUP_HP_MUTE_LED_MIC1`, which is the fixup the pin table
selects here today — that is where `/sys/class/leds/hda::mute` comes from. So the quirk adds the clamp
without changing the LED behaviour. Precedent: `103c:218b` already uses the same fixup.

Using the plain `ALC269_FIXUP_LIMIT_INT_MIC_BOOST` would drop the mute-LED fixup, because a selected
fixup replaces whatever the pin table would have chosen.

Precedence, read from the source at the baseline commit: `snd_hda_pick_fixup()` consults the model name,
then `alc269_fixup_tbl` (PCI SSID, then codec SSID), and only then `snd_hda_pick_pin_fixup()`, which
returns early if a fixup was already set. An SSID entry therefore outranks the pin match — see
`evidence/kernel-05-precedence.txt`.

## Evidence

| Claim | File |
| --- | --- |
| Codec is `ALC3227`, vendor id `0x10ec0282`, codec SSID `0x103c2164`; pin `0x12` (internal mic) reports `Amp-In caps: ofs=0x00, nsteps=0x03, stepsize=0x2f` = 4 steps x 12 dB = 36 dB | `evidence/kernel-01-codec-dump.txt` |
| Machine identity: `product_name`, `product_sku`, `board_name` | `evidence/kernel-02-dmi.txt` |
| The fixup applied today comes from a **pin match**, not an SSID entry: `ALC3227: picked fixup  (pin match)` | `evidence/kernel-03-boot-fixup.txt` |
| Upstream master has no `103c:2164` entry, and the neighbouring HP entries use the fixups named above | `evidence/kernel-04-upstream-tables.txt` |
| SSID table outranks the pin table | `evidence/kernel-05-precedence.txt` |
| `ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED` = limit + chain to `HP_MUTE_LED_MIC1`, already used for `103c:218b` | `evidence/kernel-06-fixup-definition.txt` |
| `limit-mic-boost` is a selectable model name, which makes the fixup testable without building a kernel | `evidence/kernel-07-model-name.txt` |
| Full `alsa-info` dump | `evidence/kernel-08-alsa-info.txt` |
| Upstream refs, commits and file hashes used above | `evidence/SOURCES.txt` |

`evidence/capture.sh` regenerates all of it; it only reads `/proc`, `/sys`, `journalctl`, `lsmod` and
`amixer`, and fetches the upstream sources it quotes.

## Tested behaviour, and what was not tested

Selecting the same fixup through the model name — which bypasses the SSID and pin tables — makes the
kernel log

```
snd_hda_codec_alc269 hdaudioC1D0: ALC3227: picked fixup limit-mic-boost (model specified)
```

and turns `Internal Mic Boost` from `Limits: 0 - 3` (0 to 36 dB) into `Limits: 0 - 1` (0 or 12 dB):

```sh
# /etc/modprobe.d/99-hp-pavilion-mic-boost-test.conf
options snd-hda-intel model=,limit-mic-boost
```

Note the leading comma: `model` is a `char *model[SNDRV_CARDS]` array indexed by the driver's **probe
slot**, and this laptop's HDMI controller probes first and takes slot 0. A plain
`model=limit-mic-boost` configures the HDMI codec instead and fails completely silently — the first
attempt at this test did exactly that and proved nothing. `test/mic-boost-fixup.sh` derives the slot
instead of assuming it, verifies that the option reached this codec, and prints a diagnosis when it did
not. Full write-up: `test/diagnosis-wrong-probe-slot.txt`.

Also worth knowing when reproducing: `/proc/asound/card1/codec#0` keeps printing the unclamped
`nsteps=0x03` even on success. That file reads codec parameters *uncached* by design
(`sound/hda/common/proc.c`: `#define param_read(...) snd_hdac_read_parm_uncached(...)`, "always use
noncached version"), while the fixup overrides the driver's *cached* parameter that the mixer control is
built from. The observable is `amixer -c1 sget 'Internal Mic Boost'`.

**Not tested:** the patch has not been compiled or booted (a faithful build needs the full tree for the
kernel you run). The behaviour above is the fixup's own behaviour on this hardware; that the new table
entry is *selected*, and that the chained mute-LED fixup keeps `/sys/class/leds/hda::mute` alive, rest on
the source and on the fixup definition, not on a run.

**Honest scope:** the clamp removes the two unusable steps from the hardware range. It does not by itself
make the default capture volume sane — 12 dB on top of +30 dB is still hotter than this machine's usable
operating point. That is a userspace concern, not this file's.

## Submitting

The patch is already a `git format-patch` mbox and can be mailed as it stands:

```sh
git send-email --to=linux-sound@vger.kernel.org --cc=tiwai@suse.com --cc=perex@perex.cz \
    0001-ALSA-hda-realtek-Limit-internal-mic-boost-on-HP-Pavi.patch
```

`commit-message.txt` is the message it was generated with; `verification-paragraph.txt` holds the
testing paragraph, which is already inside the patch. Addresses are those of the SOUND entry in
`MAINTAINERS` at the baseline commit.
