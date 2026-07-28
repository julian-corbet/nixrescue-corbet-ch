# checks/default.nix
#
# Wires this project's test files into `nix flake check`:
#   eval-tests.nix          -- rendering-only, no VM, no build beyond the
#                               cheap derivations the module and
#                               lib.mkMaintainer themselves produce.
#   rescue-vm-test.nix      -- a `pkgs.testers.nixosTest` that boots the
#                               rescue's own NixOS configuration DIRECTLY
#                               (no firmware, no ESP, no UKI) and exercises
#                               the boot contract, the nixfs toolchain, the
#                               GUI pointer, disk recovery and
#                               materialisation end to end. See that file's
#                               own header for why this exists and what it
#                               deliberately does not cover.
#   rescue-uefi-boot-vm-test.nix -- the OTHER half of "boots": real OVMF
#                               UEFI firmware loads a real UKI from a real
#                               ESP, the initrd resolves which cold-mode
#                               slot to mount from a pointer file (both the
#                               pointer-honoured and the
#                               bad-pointer-falls-back paths), and the
#                               overlay/nix-database mechanism the design
#                               record already verified (see that file's
#                               own header) is proved end to end, not just
#                               rendered. See experiments/README.md #001 --
#                               this is that experiment settled, now that
#                               nixboot.extraEntries has landed upstream.
#   rescue-image-fits-slot.nix -- the real `examples/rescue` closure,
#                               squashed with the exact production
#                               invocation, fails the BUILD if it would not
#                               fit its declared slot. Only meaningful on
#                               `rescueToplevel`'s own system
#                               (x86_64-linux) -- see flake.nix, which
#                               passes `null` on every other system this
#                               project's checks also run on.

{ pkgs, lib, nixpkgs, system, nixrescueModule, nixfsModule, nixbootModule, mkMaintainer, rescueToplevel ? null, slotSizeMiB ? 1024 }:

{
  eval-tests = import ./eval-tests.nix {
    inherit pkgs nixpkgs nixrescueModule mkMaintainer;
  };

  rescue-vm-test = import ./rescue-vm-test.nix {
    inherit pkgs nixpkgs nixrescueModule nixfsModule mkMaintainer;
  };

  rescue-uefi-boot-vm-test = import ./rescue-uefi-boot-vm-test.nix {
    inherit pkgs lib nixpkgs nixrescueModule nixbootModule;
  };
} // lib.optionalAttrs (rescueToplevel != null) {
  rescue-image-fits-slot = import ./rescue-image-fits-slot.nix {
    inherit pkgs slotSizeMiB;
    toplevel = rescueToplevel;
  };
}
