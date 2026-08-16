# checks/rescue-image-fits-slot.nix
#
# THE BUILD-TIME PRODUCTION GATE. It measures the real `examples/rescue` release's exact squashfs
# and fails the DERIVATION, not a `dd`, the moment that
# image would not fit its declared slot. The adjacent release-contract check builds the same
# mkRelease bundle, so size and UKI digest binding cannot accidentally inspect different images.
#
# Deliberately NOT a `pkgs.testers.nixosTest`: nothing here boots anything, so a plain
# `pkgs.runCommand` is the honest shape -- cheaper than a VM, and `nix flake check` runs it exactly
# like every other derivation-shaped check in this project.
#
# The image is already built by `lib.mkRelease`; rebuilding a lookalike here would duplicate an
# expensive compression pass and, worse, could let the size gate drift from the shipped artifact.
{ pkgs, image, slotSizeMiB }:

let
  slotSizeBytes = slotSizeMiB * 1024 * 1024;
in
pkgs.runCommand "nixrescue-image-fits-slot"
{ }
  ''
    set -euo pipefail

    size=$(stat -c%s ${image})
    slot=${toString slotSizeBytes}
    slotMiB=${toString slotSizeMiB}
    sizeMiB=$(( size / 1024 / 1024 ))

    echo "nixrescue: built image is $size bytes (~$sizeMiB MiB); declared slot is $slot bytes ($slotMiB MiB)"

    if [ "$size" -gt "$slot" ]; then
      overMiB=$(( (size - slot) / 1024 / 1024 ))
      echo "nixrescue: FAILS -- image ($sizeMiB MiB) exceeds its declared $slotMiB MiB slot by ~$overMiB MiB." >&2
      exit 1
    fi

    headroomMiB=$(( (slot - size) / 1024 / 1024 ))
    echo "nixrescue: fits, with ~$headroomMiB MiB headroom." | tee $out
  ''
