#!/bin/bash
# Test C -- prove that ALC269_FIXUP_LIMIT_INT_MIC_BOOST does what the kernel patch
# relies on, on this exact machine, WITHOUT patching or rebuilding a kernel.
#
# The fixup has a model name in alc269_fixup_models[]:
#     {.id = ALC269_FIXUP_LIMIT_INT_MIC_BOOST, .name = "limit-mic-boost"}
# and snd_hda_pick_fixup() consults model names before any SSID or pin table, so
#   snd-hda-intel.model=<slot>,<slot>,...  ->  "limit-mic-boost" for this codec
# selects the very function the patch wires to 103c:2164 -- it runs on the next
# codec probe, which means a reboot, or a module reload with the audio stack down.
#
# PREDICTION, stated before anything is run (this is what makes it a test):
#   with the option active, `amixer -c <card> sget 'Internal Mic Boost'` must report
#       Limits: 0 - 1
#   instead of `Limits: 0 - 3`: two positions (0 and 12 dB) instead of four
#   (0, 12, 24, 36 dB), and the driver must log
#       picked fixup limit-mic-boost (model specified)
#   Which codec file does NOT change, on purpose: see the note below.
#
# THE ALSA CONTROL IS THE OBSERVABLE, NOT /proc/.../codec#0 (learned 2026-09-20):
# the proc dump reads codec parameters UNCACHED -- sound/hda/common/proc.c:22,
# `#define param_read(...) snd_hdac_read_parm_uncached(...)` with the comment
# "always use noncached version" -- while the fixup installs its clamp in the
# driver's cached parameter via snd_hda_override_amp_caps() ->
# snd_hdac_override_parm(AC_PAR_AMP_IN_CAP), and the mixer control is built from
# that cached value. So `Amp-In caps: ... nsteps=0x03` in the proc file is the
# expected reading even when the fixup worked, and the first version of this
# script wrongly reported "NOT LIMITED" for a run whose control was already
# clamped to 0 - 1.
#
# THE OPTION IS AN ARRAY, AND THAT IS NOT A DETAIL (first attempt, 2026-09-20):
# `model` is `char *model[SNDRV_CARDS]`, indexed by the driver's PROBE SLOT --
# sound/hda/controllers/intel.c: `dev = find_first_zero_bit(probed_devs, ...)`,
# then `azx_bus_init(chip, model[dev])`. Every HDA controller that probes earlier
# consumes an index. This laptop has two: the HDMI controller (PCI 00:03.0) takes
# slot 0 and the ALC3227 (00:1b.0) is slot 1, so a plain `model=limit-mic-boost`
# went to the HDMI codec, which has no such model name, and the ALC3227 kept its
# pin-matched fixup. The run of 2026-09-20 20:03 shows exactly that: drop-in
# present, rebooted, caps unchanged, `picked fixup  (pin match)` again. This script
# now derives the slot instead of assuming it, and `read` says so loudly when the
# option did not reach this codec.
#
# KNOWN SIDE EFFECT while the option is active: the model selects the *unchained*
# ALC269_FIXUP_LIMIT_INT_MIC_BOOST, so /sys/class/leds/hda::mute stops being
# registered (the pin table's ALC269_FIXUP_HP_MUTE_LED_MIC1 is replaced). The kernel
# patch avoids that by chaining to the same LED fixup; this test cannot show the
# chained variant.
#
# Usage:
#   ./mic-boost-fixup.sh status                 # read the current state (no root)
#   ./mic-boost-fixup.sh install                # write the modprobe drop-in (root), then reboot
#   ./mic-boost-fixup.sh read                   # after the reboot: check the prediction, then remove
#   ./mic-boost-fixup.sh remove                 # roll back the drop-in (root), then reboot
#
# The agent that wrote this script has NO sudo on this machine, so install/remove
# have not been executed here; they were smoke-tested against MODPROBE_D.
#
# MODPROBE_D is overridable for that smoke test and for unusual layouts.

set -uo pipefail

MODPROBE_D="${MODPROBE_D:-/etc/modprobe.d}"
DROPIN_NAME=99-hp-pavilion-mic-boost-test.conf
DROPIN="$MODPROBE_D/$DROPIN_NAME"
MODEL_NAME=limit-mic-boost
here="$(cd "$(dirname "$0")" && pwd)"

# Writing to the system's modprobe directory is the only thing that needs root;
# with MODPROBE_D pointed elsewhere the check is skipped, which is how install and
# remove were smoke-tested without privileges.
needs_root() {
  [[ $MODPROBE_D == /etc/modprobe.d ]] && ((EUID != 0))
}

# The card is found by codec SSID, never by index: the HDMI codec owns card 0 and
# numbering is not guaranteed across boots.
codec_file() {
  local f
  for f in /proc/asound/card*/codec#*; do
    [[ -r $f ]] || continue
    if grep -q '^Subsystem Id: 0x103c2164' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

card_dir() {
  local f
  f="$(codec_file)" || return 1
  printf '/sys/class/sound/%s\n' "${f#/proc/asound/}" | sed 's|/codec#.*||'
}

card_number() {
  local d
  d="$(card_dir)" || return 1
  [[ $(basename "$d") =~ ^card([0-9]+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Every HDA controller, ordered by PCI address. The driver takes its probe slot in
# this order (a controller cannot probe before it is enumerated), which is what the
# `model` array is indexed by.
hda_slots() {
  local c d drv
  for c in /sys/class/sound/card[0-9]*; do
    [[ -e $c/device ]] || continue
    d="$(readlink -f "$c/device" 2>/dev/null)" || continue
    [[ -n $d ]] || continue
    drv="$(basename "$(readlink -f "$d/driver" 2>/dev/null)")"
    [[ $drv == snd_hda_intel ]] || continue
    printf '%s %s\n' "$(basename "$d")" "$(basename "$c")"
  done | sort
}

# The modprobe argument that puts MODEL_NAME on this codec's slot: as many leading
# commas as there are earlier controllers, then the name.
model_option() {
  local want addr _name i=0 n commas=""
  want="$(basename "$(readlink -f "$(card_dir)/device")")" || return 1
  while read -r addr _name; do
    if [[ $addr == "$want" ]]; then
      for ((n = 0; n < i; n++)); do commas+=","; done
      printf 'model=%s%s\n' "$commas" "$MODEL_NAME"
      return 0
    fi
    ((i++))
  done < <(hda_slots)
  return 1
}

mic_caps() {
  local f
  f="$(codec_file)" || return 1
  awk '/^Node 0x12 \[/,/^Node 0x13/' "$f" | grep -m1 'Amp-In caps'
}

mic_boost_limits() {
  local c
  c="$(card_number)" || return 1
  amixer -c "$c" sget 'Internal Mic Boost' 2>/dev/null | grep -m1 'Limits:'
}

# Proof that the option reached THIS codec: snd_hda_pick_fixup() logs the model
# name it matched, and a pinned pin-match line means it never got there.
option_reached_codec() {
  journalctl -k -b --no-pager 2>/dev/null | grep -c "picked fixup $MODEL_NAME (model specified)"
}

state() {
  echo "codec file    : $(codec_file || echo 'not found (0x103c2164 absent)')"
  echo "pin 0x12 caps : $(mic_caps || echo unknown)"
  echo "boost control : $(mic_boost_limits || echo unknown)"
  echo "drop-in       : $([[ -r $DROPIN ]] && echo "present ($DROPIN)" || echo 'absent')"
  echo "would write   : $(model_option || echo 'UNRESOLVED -- no HDA slot for this codec')"
  echo "HDA slots     : $(hda_slots | tr '\n' ' ')"
}

verdict() {
  local limits="$1" reached="$2"
  case "$limits" in
    *'Limits: 0 - 1'*)
      if ((reached)); then
        echo 'LIMITED -- prediction held: Internal Mic Boost offers 2 positions (0 and 12 dB) and the model name reached this codec'
      else
        echo "LIMITED but UNEXPLAINED -- the control is clamped without a 'model specified' line; something else clamped it, and that must be explained before this counts"
      fi
      ;;
    *'Limits: 0 - 3'*)
      if [[ -r $DROPIN ]]; then
        echo 'NOT LIMITED -- the control still offers 4 positions (0 to 36 dB), so the fixup did not take effect'
      else
        echo 'NOT LIMITED -- expected: no drop-in installed, this is the machine as shipped'
      fi
      ;;
    *)
      echo "UNKNOWN -- could not read Internal Mic Boost: ${limits:-no output}"
      ;;
  esac
}

# Why a "NOT LIMITED" verdict must not be read as "the fixup does nothing".
diagnose() {
  local reached limits
  reached="$(option_reached_codec)"
  limits="$(mic_boost_limits || echo '')"
  if [[ ! -r $DROPIN ]]; then
    return 0
  fi
  if ((reached == 0)); then
    echo
    echo "DIAGNOSIS: the drop-in is installed but the driver never matched the"
    echo "model name on this codec -- the option went to another slot. Slots are"
    echo "assigned in probe order, so re-check 'HDA slots' above and the PCI order:"
    echo "  journalctl -k -b | grep -E 'picked fixup|hdaudioC'"
    return 0
  fi
  if [[ $limits == *'Limits: 0 - 3'* ]]; then
    echo
    echo "DIAGNOSIS: the option DID reach this codec (${reached} 'model specified'"
    echo "line(s)) but the control is still 0 - 3. The fixup ran and did not clamp,"
    echo "which falsifies the premise the kernel patch rests on. Report it; do not"
    echo "send that patch."
    return 0
  fi
  echo
  echo "The option reached this codec and the control is clamped. The proc line"
  echo "'Amp-In caps: ... nsteps=0x03' is expected to stay unchanged: the proc file"
  echo "reads parameters uncached (proc.c: 'always use noncached version'), and the"
  echo "fixup overrides the driver's cached parameter that the mixer control uses."
}

case "${1:-status}" in
  status)
    state
    echo "verdict       : $(verdict "$(mic_boost_limits || echo '')" "$(option_reached_codec)")"
    diagnose
    ;;

  install)
    if needs_root; then
      echo "install needs root (writing to $MODPROBE_D): rerun with sudo." >&2
      exit 1
    fi
    option="$(model_option)" || { echo "cannot resolve the HDA slot for this codec" >&2; exit 1; }
    mkdir -p "$MODPROBE_D"
    printf '# Test C of feature omarchy-audio-upstream. Remove with:\n#   %s remove\n#\n# The model option is an array indexed by probe slot, not by card number:\n#   %s\n%s\n' \
      "$0" "$(hda_slots | tr '\n' ' ')" "options snd-hda-intel $option" > "$DROPIN"
    echo "wrote $DROPIN:"
    cat "$DROPIN"
    echo
    echo "A wrong slot is silent: no error, no log line, the option simply lands on"
    echo "another controller. $0 read checks for that."
    echo
    echo "Now reboot (simplest and safest: the codec is re-probed with nothing to"
    echo "unwind), then run:  $0 read"
    echo "Known side effect while active: /sys/class/leds/hda::mute is not registered."
    ;;

  read)
    report="$here/fixup-report-$(date +%Y%m%d-%H%M%S).txt"
    {
      echo "# Test C report -- ALC269_FIXUP_LIMIT_INT_MIC_BOOST via model=$MODEL_NAME"
      echo "# $(date -Is) on $(hostname), kernel $(uname -r), boot $(uptime -s)"
      echo "# prediction: 'Internal Mic Boost' Limits: 0 - 1 (0 or 12 dB) plus a"
      echo "#             'picked fixup $MODEL_NAME (model specified)' log line."
      echo "#             The proc 'Amp-In caps' line is NOT part of the prediction: it"
      echo "#             reads parameters uncached, so it keeps showing the hardware"
      echo "#             range even on success (see the header)."
      echo "# prediction stated in: $here/mic-boost-fixup.sh (header) before this run"
      echo
      state
      echo
      echo "verdict       : $(verdict "$(mic_boost_limits || echo '')" "$(option_reached_codec)")"
      echo
      echo "# The fixup the driver picked, and whether the model name reached it:"
      journalctl -k -b --no-pager 2>/dev/null | grep -E "picked fixup|model specified" || true
      echo "# 'model specified' lines matching $MODEL_NAME: $(option_reached_codec)"
      diagnose
    } > "$report" 2>&1
    cat "$report"
    echo
    echo "written to: $report"
    echo "Next: roll back with  sudo $0 remove   and then reboot."
    ;;

  remove)
    if needs_root; then
      echo "remove needs root (deleting $DROPIN): rerun with sudo." >&2
      exit 1
    fi
    if [[ -e $DROPIN ]]; then
      rm -f "$DROPIN"
      echo "removed $DROPIN"
    else
      echo "$DROPIN was already absent -- nothing to undo."
    fi
    echo "Reboot to re-probe the codec without the option, then confirm:  $0 status"
    ;;

  *)
    echo "Usage: $0 <status|install|read|remove>" >&2
    exit 2
    ;;
esac
