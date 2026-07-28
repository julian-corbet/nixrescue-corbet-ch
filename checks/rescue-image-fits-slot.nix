# checks/rescue-image-fits-slot.nix
#
# THE GATE `lib.mkMaintainer`'s own runtime check (../lib/mkMaintainer.nix: "refuse -- loudly,
# before writing a single byte -- if the built image would not fit the target device") cannot be,
# because it only ever runs on a real host, on a real timer, against a real device that already
# exists. This is the same check moved to BUILD time: it builds the real squashfs from the real
# `examples/rescue` closure -- the exact `mksquashfs -comp zstd -Xcompression-level 22 -b 1M`
# invocation this project's own design record measured (docs/design.md, "Storage format") -- and
# fails the DERIVATION, not a `dd`, the moment that image would not fit its declared slot. An image
# that grows too fat to ship is a build failure here, not a 2am discovery on real hardware.
#
# Deliberately NOT a `pkgs.testers.nixosTest`: nothing here boots anything, so a plain
# `pkgs.runCommand` is the honest shape -- cheaper than a VM, and `nix flake check` runs it exactly
# like every other derivation-shaped check in this project.
#
# CLOSURE COMPUTATION USES `pkgs.closureInfo`, NOT `nix-store --query --requisites` DIRECTLY --
# even though the latter is exactly what `../lib/mkMaintainer.nix`'s own script calls, on a real
# host, to build the exact same shape of image. Inside a SANDBOXED build (this check is one) there
# is no daemon socket and no Nix database to query against; `nix-store --query` would simply fail
# here regardless of what it returns on a live system. `closureInfo`'s `store-paths` file is Nix's
# own sandbox-safe mechanism for the identical fact (`exportReferencesGraph`, the same primitive
# `nixos/lib/make-squashfs.nix` itself is built on) -- same closure, same set of paths, just
# obtained the way a build is actually allowed to obtain it.
{ pkgs, toplevel, slotSizeMiB }:

let
  slotSizeBytes = slotSizeMiB * 1024 * 1024;
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
in
pkgs.runCommand "nixrescue-image-fits-slot"
{
  nativeBuildInputs = [ pkgs.squashfsTools ];
  # This check's entire job is measuring real bytes -- so unlike most checks in this repo, it does
  # a real multi-minute-at-scale mksquashfs build, not a cheap eval-only rendering. That cost is the
  # point: a size regression is what this file exists to catch before a `dd`, not after one.
}
  ''
    set -euo pipefail

    stageroot="$TMPDIR/stage"
    mkdir -p "$stageroot/nix/store"
    # shellcheck disable=SC2046
    cp -a --reflink=auto -t "$stageroot/nix/store/" $(cat "${closureInfo}/store-paths")

    image="$TMPDIR/rescue.squashfs"
    mksquashfs "$stageroot" "$image" -comp zstd -Xcompression-level 22 -b 1M -noappend

    size=$(stat -c%s "$image")
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
