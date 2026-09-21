# Deliverable C — test the fixup the kernel patch relies on, without building a kernel

`mic-boost-fixup.sh` uses the fixup's **model name** instead of a patched kernel:
`alc269_fixup_models[]` contains `{.id = ALC269_FIXUP_LIMIT_INT_MIC_BOOST, .name = "limit-mic-boost"}`,
and `snd_hda_pick_fixup()` consults model names before any SSID or pin table. So

```sh
# /etc/modprobe.d/99-hp-pavilion-mic-boost-test.conf
options snd-hda-intel model=,limit-mic-boost
```

runs the same `alc269_fixup_limit_int_mic_boost()` function that the kernel patch wires to `103c:2164`,
on the next codec probe.

**The leading comma is load-bearing.** `model` is `char *model[SNDRV_CARDS]`, indexed by the driver's
probe slot (`intel.c`: `dev = find_first_zero_bit(probed_devs, …)` then `azx_bus_init(chip, model[dev])`),
and this laptop's HDMI controller probes first and takes slot 0, leaving the ALC3227 in slot 1. A plain
`model=limit-mic-boost` silently configures the HDMI codec instead — which is exactly what the first
attempt did, see `diagnosis-20260920-wrong-probe-slot.txt`. The script derives the slot rather than
assuming it, and prints the slot table and the option line it would write.

## Usage

```sh
./mic-boost-fixup.sh status    # read the current state, no root needed
./mic-boost-fixup.sh install   # write the drop-in (root), then reboot
./mic-boost-fixup.sh read      # after the reboot: check the prediction, write the report
./mic-boost-fixup.sh remove    # roll back (root), then reboot
```

If `status` or `read` prints a DIAGNOSIS block, the option did not reach this codec: the slot it was
written for is not the slot this device probes in. Check the `HDA slots` line, which lists the
controllers in the order the driver claims slots.

The prediction is stated in the script header **before** anything runs: `Internal Mic Boost` must report
`Limits: 0 - 1` (two positions: 0 and 12 dB) instead of `Limits: 0 - 3` (four positions: 0, 12, 24,
36 dB), and the driver must log `picked fixup limit-mic-boost (model specified)`. The `/proc` codec dump
is deliberately **not** part of the prediction: it reads codec parameters uncached and keeps showing the
hardware range even when the clamp is active.

## State of this deliverable

**Test C passed on 2026-09-20 (boot 20:13:13).** With `model=,limit-mic-boost` active the driver
selected the fixup —

```
snd_hda_codec_alc269 hdaudioC1D0: ALC3227: picked fixup limit-mic-boost (model specified)
```

— and `Internal Mic Boost` reports `Limits: 0 - 1` (0 or 12 dB) instead of `Limits: 0 - 3` (0 to
36 dB). Evidence: `fixup-report-20260920-201757.txt` (the raw run) and
`fixup-report-20260920-202008.txt` (a re-read of the same boot through the corrected verdict).

### The two corrections this test needed, both kept as evidence

1. **Attempt 1 (20:03) was inconclusive because the option targeted the wrong controller.**
   `snd-hda-intel`'s `model` is an array indexed by the driver's probe slot; the HDMI controller
   takes slot 0 here, so a plain `model=limit-mic-boost` configured it and the ALC3227 kept its
   pin-matched fixup. Fixed by writing `model=,limit-mic-boost` and deriving the slot instead of
   assuming it. See `diagnosis-20260920-wrong-probe-slot.txt`.
2. **The verdict was keyed on the wrong observable.** `/proc/asound/cardN/codec#*` reads codec
   parameters *uncached* — `sound/hda/common/proc.c` says so in a comment on the `param_read` macro —
   while the fixup overrides the driver's *cached* parameter, which is what the mixer control is built
   from. So `Amp-In caps: … nsteps=0x03` stays in the proc file even when the clamp is active, and the
   first version of this script reported NOT LIMITED for a run whose control was already clamped. The
   prediction now names only the control and the driver's log line.

### What is still not established

- No build or boot of the patched kernel (see `../README.md`): the fixup's own behaviour is now
  proven, the SSID selection is not.
- The mute-LED side effect of the *test* (the model name selects the unchained fixup) means the chained
  `ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED` used by the patch is still unexercised.
- `install` and `remove` were smoke-tested against `MODPROBE_D` pointed at a scratch directory; the
  system-modifying path was executed by the user, not by the agent, which has no `sudo` here.
- The machine is still carrying the test drop-in until `sudo ./mic-boost-fixup.sh remove` and a reboot.

## Known side effect while the option is active

`model=` **replaces** the fixup that the pin table selects, which on this machine is
`ALC269_FIXUP_HP_MUTE_LED_MIC1`: `/sys/class/leds/hda::mute` stops being registered. Two consequences:

- It is a property of the test, not of the patch — the patch chains to the same LED fixup through
  `ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED`. The test selects the *unchained*
  `ALC269_FIXUP_LIMIT_INT_MIC_BOOST`, so **the LED behaviour the patch preserves is not exercised by
  anything in this package**; do not claim otherwise, in the commit message or in the mail.
- What this test does establish is the boost clamp: the same `alc269_fixup_limit_int_mic_boost()`
  function runs, on this codec, and the pin caps change as predicted.

`ALC269_FIXUP_LIMIT_INT_MIC_BOOST` itself (line 4890 of `evidence/upstream/alc269.c`) has no `.chained`,
which is what makes this distinction real rather than pedantic.
