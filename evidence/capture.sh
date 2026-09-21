#!/bin/bash
# Capture the evidence package for feature omarchy-audio-upstream.
#
# Read-only against the system: every command below only reads /proc, /sys,
# journalctl, the installed Omarchy tree and the network. Nothing is installed,
# reloaded or reconfigured. Re-runnable: it fetches the upstream sources into
# ./upstream and records their sha256 next to every claim that quotes them.
#
# Usage:  ./capture.sh          (from odd/omarchy-audio-upstream/evidence/)

# No `set -e`: a read command that fails is itself evidence worth recording in
# the file it writes to. Fetch failures are checked explicitly instead.
set -uo pipefail

cd "$(dirname "$0")"
out="$PWD"
up="$out/upstream"
mkdir -p "$up"

LINUX_MASTER_SHA=a10a019dd4c7c57bef6b8dda962c8881ad220af2
LINUX_RAW=https://raw.githubusercontent.com/torvalds/linux/$LINUX_MASTER_SHA
# Canonical repository and ref. `basecamp/omarchy` redirects here, and the default
# branch is `quattro`, not `master`: a `master` fetch still serves the same bytes
# through GitHub's rename alias, which is exactly what makes the wrong name easy to
# keep using. The commit recorded in SOURCES.txt is the pin.
OMARCHY_REPO=https://github.com/omacom/omarchy
OMARCHY_REF=quattro
OMARCHY_RAW=https://raw.githubusercontent.com/omacom/omarchy/$OMARCHY_REF
NOW="$(date -Is)"
HOST="$(hostname)"
KERNEL="$(uname -r)"

# ---------------------------------------------------------------- provenance

fetch() { # fetch <url> <local-name>
  curl -sS --fail -o "$up/$2" "$1"
  printf '%s  %s\n' "$(sha256sum "$up/$2" | cut -d' ' -f1)" "$2"
}

provenance() { # provenance <title> <kernel-source?> <upstream-file...>
  local title="$1"; shift
  echo "# $title"
  echo "# captured:   $NOW on $HOST, kernel $KERNEL"
  echo "# capture.sh: odd/omarchy-audio-upstream/evidence/capture.sh (re-runnable, read-only)"
  echo "# linux source: torvalds/linux master $LINUX_MASTER_SHA ($LINUX_RAW/)"
  echo "# omarchy source: omacom/omarchy $OMARCHY_REF ${OMARCHY_SHA:-unknown at capture time} ($OMARCHY_RAW/)"
  local f
  for f in "$@"; do
    echo "#   $f sha256 $(sha256sum "$up/$f" | cut -d' ' -f1)"
  done
  echo
}

# ------------------------------------------------------------ upstream files

{
  echo "# Upstream sources used as the baseline for this feature."
  echo "# captured: $NOW on $HOST"
  echo "# linux:   torvalds/linux master $LINUX_MASTER_SHA via $LINUX_RAW"
  echo "# omarchy: $OMARCHY_REPO ref $OMARCHY_REF via $OMARCHY_RAW"
  echo "#          (basecamp/omarchy redirects to omacom/omarchy, and the default branch"
  echo "#           is quattro, which is why a 'master' lookup returns nothing)"
  echo
  echo "## git ls-remote --symref $OMARCHY_REPO HEAD"
  timeout 90 git ls-remote --symref "$OMARCHY_REPO" HEAD || echo "(unavailable)"
  echo
  echo "## git ls-remote $OMARCHY_REPO refs/heads/$OMARCHY_REF"
  timeout 90 git ls-remote "$OMARCHY_REPO" "refs/heads/$OMARCHY_REF" || echo "(unavailable)"
  echo
  echo "## git ls-remote $OMARCHY_REPO refs/heads/master   (expected: empty, no such branch)"
  timeout 90 git ls-remote "$OMARCHY_REPO" refs/heads/master || true
  echo
  echo "## git ls-remote torvalds/linux master"
  timeout 90 git ls-remote https://github.com/torvalds/linux master || echo "(unavailable)"
  echo
  echo "## sha256 of fetched files"
} > SOURCES.txt

OMARCHY_SHA="$(timeout 90 git ls-remote "$OMARCHY_REPO" "refs/heads/$OMARCHY_REF" 2>/dev/null | cut -f1 || true)"
if [[ -n ${OMARCHY_SHA:-} ]]; then
  printf '# omacom/omarchy %s at capture time: %s\n' "$OMARCHY_REF" "$OMARCHY_SHA" >> SOURCES.txt
else
  echo '# omacom/omarchy: ls-remote unavailable at capture time; the sha256 below identify the exact bytes' >> SOURCES.txt
fi

{
  echo "alc269.c   $(fetch "$LINUX_RAW/sound/hda/codecs/realtek/alc269.c" alc269.c)"
  echo "auto_parser.c $(fetch "$LINUX_RAW/sound/hda/common/auto_parser.c" auto_parser.c)"
  echo "audio-tuning.md $(fetch "$OMARCHY_RAW/docs/audio-tuning.md" audio-tuning.md)"
  echo "omarchy-audio-tuning $(fetch "$OMARCHY_RAW/bin/omarchy-audio-tuning" omarchy-audio-tuning)"
  echo "omarchy-audio-sink-availability $(fetch "$OMARCHY_RAW/bin/omarchy-audio-sink-availability" omarchy-audio-sink-availability)"
  echo "omarchy-audio-output-sink $(fetch "$OMARCHY_RAW/bin/omarchy-audio-output-sink" omarchy-audio-output-sink)"
  echo "omarchy-audio-output-switch $(fetch "$OMARCHY_RAW/bin/omarchy-audio-output-switch" omarchy-audio-output-switch)"
} >> SOURCES.txt


# ------------------------------------------------------- 01 live codec dump

{
  provenance "Live codec: identity, and the internal-mic pin amp that is not clamped" alc269.c auto_parser.c
  echo "\$ grep -H '^Codec:\|^Subsystem Id\|^Vendor Id' /proc/asound/card1/codec#0"
  grep -H '^Codec:\|^Subsystem Id\|^Vendor Id' /proc/asound/card1/codec#0
  echo
  echo "\$ awk '/^Node 0x12 \[/,/^Node 0x13/' /proc/asound/card1/codec#0"
  awk '/^Node 0x12 \[/,/^Node 0x13/' /proc/asound/card1/codec#0
  echo
  echo "\$ awk '/^Node 0x19 \[/,/^Node 0x1a/' /proc/asound/card1/codec#0 | head -12"
  awk '/^Node 0x19 \[/,/^Node 0x1a/' /proc/asound/card1/codec#0 | head -12
  echo
  echo "\$ awk '/^Node 0x21 \[/,/^Node 0x22/' /proc/asound/card1/codec#0 | head -12"
  awk '/^Node 0x21 \[/,/^Node 0x22/' /proc/asound/card1/codec#0 | head -12
  echo
  echo "# Reading of the numbers, for the report: node 0x12 (Internal Mic) is the"
  echo "# internal input pin, and its Amp-In caps read ofs=0x00, nsteps=0x03,"
  echo "# stepsize=0x2f. Step size 0x2f -> (0x2f+1)*0.25 dB = 12 dB per step, and"
  echo "# nsteps=0x03 means 4 positions: 0/12/24/36 dB -- the full 36 dB range"
  echo "# alc269_fixup_limit_int_mic_boost() exists to clamp to 0 or 12 dB."
  echo
  echo "\$ amixer -c 1 sget 'Internal Mic Boost' (32 bits of state a user can move: Limits 0-3)"
  amixer -c 1 sget 'Internal Mic Boost' 2>&1 | head -10
  echo
  echo "\$ ls /sys/class/leds/   (hda::mute is registered by the fixup this machine already gets)"
  ls /sys/class/leds/
} > kernel-01-codec-dump.txt

# ---------------------------------------------------------------- 02 machine

{
  provenance "Machine identity used to justify the SSID quirk"
  for f in sys_vendor product_name product_family product_version product_sku board_name bios_version; do
    printf '%-16s %s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo '(unreadable)')"
  done
} > kernel-02-dmi.txt

# ------------------------------------------------------- 03 which fixup ran

{
  provenance "Which fixup the driver actually picked, and where it came from"
  echo "\$ journalctl -k -b --no-pager | grep -E 'picked fixup|autoconfig for|Internal Mic='"
  journalctl -k -b --no-pager | grep -E 'picked fixup|autoconfig for|Internal Mic=' || true
  echo
  echo "# '(pin match)' is the point of this file: no SSID entry matched, so the"
  echo "# fixup came from the pin table (alc269_pin_fixup_tbl). The empty name is"
  echo "# the pre-existing printing of a pin-quirk name."
  echo
  echo "\$ lsmod | grep -E 'snd_hda_codec|snd_hda_intel'"
  lsmod | grep -E 'snd_hda_codec|snd_hda_intel'
  echo
  echo "\$ modinfo -p snd_hda_intel | grep '^model'   (where a model= test would be applied)"
  modinfo -p snd_hda_intel | grep '^model'
} > kernel-03-boot-fixup.txt

# --------------------------------------------------- 04 upstream quirk tables

{
  provenance "Upstream master: no SSID entry for this machine, and the shape of the tables" \
    alc269.c
  echo "\$ grep -n '2164' alc269.c        # the codec SSID is 0x103c2164"
  grep -n '2164' "$up/alc269.c" || echo '(no match: the SSID is absent from the file)'
  echo
  echo "\$ grep -n '^static const struct hda_quirk\|^static const struct snd_hda_pin_quirk\|^static const struct hda_model_fixup' alc269.c"
  grep -n '^static const struct hda_quirk\|^static const struct snd_hda_pin_quirk\|^static const struct hda_model_fixup' "$up/alc269.c"
  echo
  echo "\$ grep -n 'SND_PCI_QUIRK(0x103c' alc269.c | head -20   (where the new line goes)"
  grep -n 'SND_PCI_QUIRK(0x103c' "$up/alc269.c" | head -20
  echo
  echo "\$ grep -n 'SND_PCI_QUIRK_VENDOR(0x103c' alc269.c"
  grep -n 'SND_PCI_QUIRK_VENDOR(0x103c' "$up/alc269.c"
  echo
  echo "\$ grep -n -A4 'SND_HDA_PIN_QUIRK(0x10ec0282, 0x103c' alc269.c   (the entries that can match this machine)"
  grep -n -A4 'SND_HDA_PIN_QUIRK(0x10ec0282, 0x103c' "$up/alc269.c"
  echo
  echo "# Live pin defaults for comparison, from kernel-01-codec-dump.txt:"
  echo "#   0x12 0x99a30130 | 0x19 0x03a11020 | 0x21 0x03211040"
  echo "# Those are exactly the pins of the second 'HP' entry above"
  echo "# (ALC269_FIXUP_HP_MUTE_LED_MIC1). The pin table is an identity test in"
  echo "# current kernels -- snd_hda_pick_pin_fixup() only compares pins and sets"
  echo "# fixup_id; it does not write them -- so replacing the match with an SSID"
  echo "# entry loses no pin configuration. That is the argument the patch rests"
  echo "# on, and test C (model=limit-mic-boost) is what proves it on this machine."
} > kernel-04-upstream-tables.txt

# ----------------------------------------------------------- 05 precedence

{
  provenance "SSID table outranks the pin table, so the one-line SSID quirk takes effect" \
    auto_parser.c alc269.c
  echo "== sound/hda/common/auto_parser.c: snd_hda_pick_pin_fixup() -- early return =="
  sed -n '/^void snd_hda_pick_pin_fixup/,/^EXPORT_SYMBOL_GPL(snd_hda_pick_pin_fixup);/p' "$up/auto_parser.c"
  echo
  echo "== sound/hda/common/auto_parser.c: snd_hda_pick_fixup() -- model first, then SSID =="
  sed -n '/^ \* snd_hda_pick_fixup - Pick up a fixup/,/^}\$/p' "$up/auto_parser.c"
  echo
  echo "== sound/hda/codecs/realtek/alc269.c: the call order =="
  sed -n '/snd_hda_pick_fixup(codec, alc269_fixup_models,/,/alc269_fixup_vendor_tbl/p' "$up/alc269.c"
} > kernel-05-precedence.txt

# --------------------------------------------------- 06 the fixup to select

{
  provenance "ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED already is 'limit boost + HP mute LED'" \
    alc269.c
  echo "== the helper the fixup runs =="
  sed -n '/^static void alc269_fixup_limit_int_mic_boost(/,/^}/p' "$up/alc269.c"
  echo
  echo "== the fixup entry: chained onto the very fixup this machine gets today =="
  sed -n '/^\t\[ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED\] = {/,/^\t},/p' "$up/alc269.c"
  echo
  echo "== the LED fixup it chains to (what the boot log's pin match selected) =="
  sed -n '/^\t\[ALC269_FIXUP_HP_MUTE_LED_MIC1\] = {/,/^\t},/p' "$up/alc269.c"
  echo
  echo "== precedent: another HP SSID already uses exactly this combination =="
  grep -n 'ALC269_FIXUP_LIMIT_INT_MIC_BOOST_MUTE_LED' "$up/alc269.c"
  echo
  echo "== our machine's pin-match fixup, for the comparison =="
  grep -n 'ALC269_FIXUP_HP_MUTE_LED_MIC1' "$up/alc269.c"
} > kernel-06-fixup-definition.txt

# ---------------------------------------------------- 07 the testable model

{
  provenance "Why the fixup can be tested without building a kernel: it has a model name" alc269.c
  grep -n 'limit-mic-boost' "$up/alc269.c"
  echo
  echo "== the model list is consulted before any SSID lookup =="
  grep -n 'alc269_fixup_models\[\]' "$up/alc269.c"
  echo
  echo "# So: options snd-hda-intel model=limit-mic-boost selects"
  echo "# ALC269_FIXUP_LIMIT_INT_MIC_BOOST -- the plain limit, NOT the chained"
  echo "# mute-LED variant. In that configuration the SSID and pin tables are"
  echo "# skipped entirely (goto found), which is exactly why the kernel patch"
  echo "# must chain to the LED fixup instead of using the plain one."
} > kernel-07-model-name.txt

# ---------------------------------------------------------- 08 alsa-info

{
  provenance "alsa-info for the bug report (dmesg is unavailable without root, and is not needed:
# kernel-03 already carries the HDA lines from the journal)"
  echo "\$ alsa-info.sh --stdout --with-dmesg --with-pkgs"
  echo
  # --output silently produced nothing here; --stdout redirects fine.
  timeout 180 alsa-info.sh --stdout --with-dmesg --with-pkgs 2>/dev/null || true
} > kernel-08-alsa-info.txt

# ------------------------------------------------------- 09 omarchy: the bug

{
  provenance "Live behaviour of the installed Omarchy audio scripts on this machine" \
    omarchy-audio-tuning omarchy-audio-sink-availability omarchy-audio-output-sink
  echo "\$ omarchy audio tuning status"
  omarchy audio tuning status 2>&1 || true
  echo
  echo "\$ omarchy audio tuning fronted-sink ; echo exit=\$?"
  omarchy audio tuning fronted-sink 2>&1; echo "exit=$?"
  echo
  echo "\$ omarchy audio output sink omarchy_speaker_tuning   <-- the resolution that works"
  omarchy audio output sink omarchy_speaker_tuning 2>&1
  echo
  echo "\$ omarchy audio output sink ; echo exit=\$?"
  omarchy audio output sink 2>&1; echo "exit=$?"
  echo
  echo "\$ omarchy-audio-sink-availability    (both sinks reported available = the bug)"
  omarchy-audio-sink-availability 2>&1
  echo
  echo "\$ pactl list sinks short"
  pactl list sinks short 2>&1
  echo
  echo "# Expected after the fix: the physical sink must read 0 (unavailable) while"
  echo "# the tuning sink reads 1, because the tuning is installed and fronting."
} > omarchy-01-fronted-sink.txt

# ------------------------------------------- 09 omarchy: upstream == install

{
  provenance "Upstream $OMARCHY_REF is byte-identical to the installed 4.0.4 scripts" \
    omarchy-audio-tuning omarchy-audio-sink-availability omarchy-audio-output-sink
  echo "\$ omarchy (installed) version"
  cat /usr/share/omarchy/version
  echo "package: $(pacman -Q omarchy 2>/dev/null || echo unknown)"
  echo
  echo "# The installed scripts are compared against the upstream ref fetched above"
  echo "# (omacom/omarchy $OMARCHY_REF, ${OMARCHY_SHA:-unknown}). Byte equality is the"
  echo "# claim; the ref name is only how those bytes are addressed."
  echo
  for s in omarchy-audio-tuning omarchy-audio-sink-availability omarchy-audio-output-sink; do
    echo "== $s =="
    echo "installed: $(sha256sum "/usr/share/omarchy/bin/$s" | cut -d' ' -f1)"
    echo "upstream : $(sha256sum "$up/$s" | cut -d' ' -f1)"
    if diff -q "/usr/share/omarchy/bin/$s" "$up/$s" >/dev/null; then
      echo "diff      : identical"
    else
      echo "diff      : DIFFERS -- unchanged-upstream claim would not hold"
      diff -u "/usr/share/omarchy/bin/$s" "$up/$s" | head -40
    fi
    echo
  done
} > omarchy-02-upstream-identity.txt

# --------------------------------------- 10 omarchy: the resolver to reuse

{
  provenance "The primitive the fix reuses already exists in the same script family" \
    omarchy-audio-output-sink omarchy-audio-tuning
  echo "== installed omarchy-audio-output-sink (resolves a DSP sink to its target) =="
  cat /usr/share/omarchy/bin/omarchy-audio-output-sink
  echo
  echo "== omarchy-audio-tuning: the helper that already does this =="
  sed -n '/^tuning_downstream_sink()/,/^}/p' /usr/share/omarchy/bin/omarchy-audio-tuning
  echo
  echo "== omarchy-audio-tuning: the branch that ignores it =="
  sed -n '/^  fronted-sink)/,/^    ;;/p' /usr/share/omarchy/bin/omarchy-audio-tuning
  echo
  echo "== omarchy-audio-tuning: what it answers from instead (needs a shipped tuning) =="
  sed -n '/^tuned_hardware_sink()/,/^}/p' /usr/share/omarchy/bin/omarchy-audio-tuning
  echo
  echo "# Note the idle case, which the fix must guard: with the tuning sink present"
  echo "# but its chain unlinked, omarchy-audio-output-sink falls back to printing the"
  echo "# sink itself. Without a guard the availability script would then mark the"
  echo "# TUNING sink unavailable -- worse than the bug being fixed."
} > omarchy-03-downstream.txt

# ------------------------------------------------- 11 omarchy: the contract

{
  provenance "The documented behaviour this machine violates" audio-tuning.md
  grep -n -B4 -A6 'The fronted sink is hidden' "$up/audio-tuning.md"
  echo
  echo "\$ grep -rn 'fronted-sink' /usr/share/omarchy/   (who consumes the answer)"
  grep -rn 'fronted-sink' /usr/share/omarchy/ 2>/dev/null || true
  echo
  echo "\$ omarchy-audio-output-switch uses the same answer:"
  grep -n 'fronted' /usr/share/omarchy/bin/omarchy-audio-output-switch
} > omarchy-04-doc-contract.txt

# ------------------------------------------------------------- completeness

missing=0
for f in SOURCES.txt kernel-01-codec-dump.txt kernel-02-dmi.txt kernel-03-boot-fixup.txt \
  kernel-04-upstream-tables.txt kernel-05-precedence.txt kernel-06-fixup-definition.txt \
  kernel-07-model-name.txt kernel-08-alsa-info.txt omarchy-01-fronted-sink.txt omarchy-02-upstream-identity.txt \
  omarchy-03-downstream.txt omarchy-04-doc-contract.txt; do
  if [[ ! -s $out/$f ]]; then
    echo "INCOMPLETE: $f is missing or empty" >&2
    missing=1
  fi
done
for f in $up/*; do
  if [[ ! -s $f ]]; then
    echo "INCOMPLETE: fetched file $f is empty (network failure?)" >&2
    missing=1
  fi
done

if ((missing)); then
  echo "evidence capture FAILED -- see above" >&2
  exit 1
fi

echo "evidence captured in $out"
ls -1 "$out"/*.txt
