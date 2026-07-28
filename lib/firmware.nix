# lib/firmware.nix
#
# THE GAP. `hardware.enableRedistributableFirmware = true` hands the kernel the ENTIRE
# `linux-firmware` package -- every vendor's blobs, for hardware this image will never see. Inside
# a squashfs image meant to fit a small, fixed-size slot, that is not a rounding error: it is the
# single largest thing in the closure after the toplevel itself. Symlinks do not help --
# `hardware.firmware`'s own `apply` (nixpkgs' `nixos/modules/services/hardware/udev.nix`) resolves
# every package it is handed into a real, deduplicated `buildEnv` before compression ever runs, so
# an uncurated `hardware.firmware = [ pkgs.linux-firmware ]` ships every referenced byte regardless
# of how the source package happens to lay them out on disk.
#
# THE FIX: name the subtrees this rescue actually needs, once, as a reviewable LIST -- the same
# shape nixfs keeps its own filesystem/tool catalogue as data (`nixfs/lib/catalogue.nix`) rather
# than logic -- and copy each one WHOLE out of the upstream package. `mkCuratedFirmware` below does
# the copying; this file's only real content is the list.
#
# THREE TRAPS, ALL VERIFIED AGAINST A REAL `linux-firmware` TREE, NOT ASSUMED:
#
#   (a) THE FLAT NAME TRAP. A driver requests firmware by a FLAT name --
#       `request_firmware(&fw, "iwlwifi-so-a0-gf-a0-89.ucode", dev)`, never
#       "intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode" -- and upstream `linux-firmware` satisfies that
#       with a SYMLINK sitting directly at the top of `lib/firmware/`, pointing INTO the vendor
#       directory where the real bytes live. Copying a vendor directory copies the real bytes;
#       it does NOT copy the flat-name symlink that points at them, because that symlink does not
#       live inside the directory being copied -- it lives as a sibling, one level up. Miss it and
#       the vendor directory is present, intact, and completely unreachable by the one name the
#       kernel actually asks for: the build succeeds, the image boots, and the device simply never
#       binds its firmware. This is not specific to wireless -- verified here for `intel/` (202
#       such top-level symlinks in a real build) and `mediatek/` (4) -- so `mkCuratedFirmware`
#       resolves every top-level symlink whose target falls under a SELECTED subtree and recreates
#       it, rather than hand-listing glob patterns like "iwlwifi-*" that would silently miss
#       whichever flat name someone didn't think to type.
#
#   (b) THE PARTIAL-VENDOR-DIRECTORY TRAP. Do not trim inside a subtree once it is selected. A
#       vendor directory is not a flat pile of interchangeable files -- it is one hardware
#       generation's firmware next to the next generation's, and the specific file a given board
#       revision binds to is not something to guess from a filename. A partially-curated vendor
#       directory looks identical to a complete one until the day a device stops binding, which is
#       exactly the failure mode curation exists to avoid, not introduce. Whole directories, always.
#
#   (c) THE CROSS-VENDOR-SYMLINK TRAP. A selected directory's OWN internal symlinks are not
#       guaranteed to stay inside it. Verified here: 9 of `intel/`'s own symlinks -- every one
#       under `intel/ish/`, the Integrated Sensor Hub blobs -- point sideways past `intel/`
#       entirely, into per-OEM directories this list never selects (`dell/ish/...`, `HP/ish/...`,
#       `LENOVO/ish/...`; several laptop vendors' ISH firmware turns out to be a re-badge of a
#       shared blob filed under whichever OEM shipped it first). Copying `intel/` whole, per trap
#       (b), copies that symlink verbatim -- pointing at a directory this curation never
#       materialises. This is the flat-name trap's other shape: present, intact, and dead the
#       moment the source it points at is not there. `mkCuratedFirmware` closes it not by chasing
#       every OEM directory a future upstream release might reuse (an unbounded, silently-stale
#       list), but by resolving every symlink that copied dangling against the FULL, uncurated
#       source tree -- which always resolves, being the whole package -- and inlining the real
#       bytes in its place.
#
{}:

let
  # ── The reviewable list. Add or drop a subtree here, nowhere else. ─────────────────────────────
  #
  # Each name is a whole top-level directory under `linux-firmware`'s `lib/firmware/`. Coverage is
  # deliberately narrow: the graphics and wireless vendors an x86 rescue actually meets, plus CPU
  # microcode, not "every vendor nixpkgs happens to package".
  #
  # Named `defaultSubtrees`, not `subtrees`, on purpose: `mkCuratedFirmware`'s own `subtrees ? ...`
  # argument below needs a DIFFERENT name to default to. A Nix pattern argument's default is
  # resolved in a scope that includes every sibling argument name, so `subtrees ? subtrees` would
  # not reach this outer binding at all -- it would resolve to the argument itself and blackhole
  # ("infinite recursion encountered") the moment a caller omits it. Verified, not theoretical.
  defaultSubtrees = [
    "amdgpu" # AMD GPU firmware -- discrete and integrated alike.
    "i915" # Intel integrated graphics, the pre-Xe generations.
    "xe" # Intel integrated graphics, the Xe-and-later generations (i915's successor driver).
    "intel" # Intel wireless (iwlwifi) plus the Bluetooth combo firmware shipped alongside it.
    "mediatek" # MediaTek wireless (the mt76xx family).
    "amd-ucode" # AMD CPU microcode -- loaded by the kernel/initrd at boot, before any driver runs.
  ];
in
{
  subtrees = defaultSubtrees;

  # mkCuratedFirmware :: { pkgs, source ? pkgs.linux-firmware, subtrees ? defaultSubtrees } -> derivation
  #
  # Returns a derivation shaped like `linux-firmware` itself (`lib/firmware/...`), suitable to drop
  # straight into `hardware.firmware = [ (mkCuratedFirmware { inherit pkgs; }) ]` alongside
  # `hardware.enableRedistributableFirmware = false` -- compression is still applied downstream, by
  # the option's own `apply`, exactly as it would be for the uncurated package. This derivation only
  # decides WHICH bytes reach that step.
  mkCuratedFirmware =
    { pkgs
    , source ? pkgs.linux-firmware
    , subtrees ? defaultSubtrees
    }:
    pkgs.runCommand "linux-firmware-curated"
      {
        # Not a build-time input to anything downstream; keeps `nix why-depends` honest about what
        # actually pulled this in.
        passthru = { inherit subtrees source; };
      }
      ''
        set -euo pipefail

        src="${source}/lib/firmware"
        dst="$out/lib/firmware"
        mkdir -p "$dst"

        subtrees="${builtins.concatStringsSep " " subtrees}"

        for dir in $subtrees; do
          if [ ! -d "$src/$dir" ]; then
            echo "nixrescue firmware curation: '$dir' is not a directory in ${source} -- check lib/firmware.nix's subtree list" >&2
            exit 1
          fi
          cp -a --reflink=auto "$src/$dir" "$dst/$dir"
        done

        # Trap (a): recreate every top-level flat-name symlink whose target resolves into one of
        # the directories just copied -- not a hand-picked glob, every one of them.
        find "$src" -maxdepth 1 -type l -print0 |
          while IFS= read -r -d "" link; do
            name=$(basename "$link")
            target=$(readlink "$link")
            for dir in $subtrees; do
              case "$target" in
                "$dir"/*)
                  cp -a "$link" "$dst/$name"
                  break
                  ;;
              esac
            done
          done

        # `cp -a` preserves the source tree's own permission bits, and a Nix store directory is
        # read-only (mode 555) -- so without this, the fixup pass below cannot even unlink a
        # dangling symlink to replace it, let alone the vendor-directory copies further up ever
        # being editable again. Everything under $dst is about to become part of $out, which Nix
        # makes read-only for everyone once this derivation finishes building regardless of what
        # its build user can write to in the meantime.
        chmod -R u+w "$dst"

        # Trap (c): any symlink now sitting in $dst -- whether copied whole with its vendor
        # directory or recreated just above -- that does not resolve to a real file INSIDE the
        # curated tree gets dereferenced against the full source tree instead, which always
        # resolves. A single pass over the whole staged tree catches both cases uniformly; nothing
        # here needs to know which subtree or which OEM a dangling link happened to point at.
        find "$dst" -type l -print0 |
          while IFS= read -r -d "" link; do
            [ -e "$link" ] && continue
            rel="''${link#"$dst"/}"
            resolved=$(readlink -f "$src/$rel")
            if [ ! -e "$resolved" ]; then
              echo "nixrescue firmware curation: '$rel' is dangling even against the full, uncurated source tree -- this should never happen" >&2
              exit 1
            fi
            rm -f "$link"
            cp -a --reflink=auto "$resolved" "$link"
          done
      '';
}
