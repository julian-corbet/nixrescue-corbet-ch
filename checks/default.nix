# checks/default.nix
#
# Wires this project's test files into `nix flake check`:
#   eval-tests.nix          -- rendering-only, no VM, no build beyond the
#                               cheap derivations the module produces.
#   rescue-vm-test.nix      -- a `pkgs.testers.nixosTest` that boots the
#                               rescue's own NixOS configuration DIRECTLY
#                               (no firmware, no ESP, no UKI) and exercises
#                               the boot contract, the nixfs toolchain, the
#                               GUI pointer, and disk recovery end to end.
#                               See that file's
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
#                               rendered.
#   rescue-image-fits-slot.nix -- the real `examples/rescue` release image
#                               fails the BUILD if it would not fit its
#                               declared slot. Only meaningful on
#                               `rescueRelease`'s own system
#                               (x86_64-linux) -- see flake.nix, which
#                               passes `null` on every other system this
#                               project's checks also run on. The adjacent
#                               release-contract output proves that exact
#                               image digest is embedded in the UKI.
#   reconciler-vm-test.nix -- writes and verifies both a real A/B/C GPT
#                               medium and an independent explicit one-slot
#                               GPT medium, including the no-mutation reject
#                               path and repeat idempotence.

{ pkgs, lib, nixpkgs, system, nixrescueModule, overlayStoreModule, nixfsModule, mkUki, mkReconciler, rescueRelease ? null, slotSizeMiB ? 1024 }:

{
  eval-tests = import ./eval-tests.nix {
    inherit pkgs nixpkgs nixrescueModule;
  };

  rescue-vm-test = import ./rescue-vm-test.nix {
    inherit pkgs nixpkgs nixrescueModule nixfsModule;
  };

  rescue-uefi-boot-vm-test = import ./rescue-uefi-boot-vm-test.nix {
    inherit pkgs lib nixpkgs nixrescueModule overlayStoreModule mkUki;
  };

  # Building writeShellApplication runs shellcheck over the complete generated actuator.
  # Fake paths are sufficient here: runtime media behavior is covered by the UEFI VM, while
  # this boundary catches quoting and Bash-generation failures before a host can import it.
  reconciler-script = mkReconciler {
    inherit pkgs;
    name = "syntax-check";
    release = pkgs.runCommand "nixrescue-fake-release" { } ''
      mkdir -p "$out"
      touch "$out/image" "$out/uki.efi" "$out/init-path"
    '';
    slots = [
      "/dev/disk/by-partlabel/nixrescue-a"
      "/dev/disk/by-partlabel/nixrescue-b"
      "/dev/disk/by-partlabel/nixrescue-c"
    ];
  };

  reconciler-vm-test = import ./reconciler-vm-test.nix {
    inherit pkgs lib mkReconciler;
  };
} // lib.optionalAttrs (rescueRelease != null) {
  # Building the bundle proves mkRelease rejects a UKI that does not embed its image digest/size.
  release-contract = rescueRelease.bundle;

  rescue-image-fits-slot = import ./rescue-image-fits-slot.nix {
    inherit pkgs slotSizeMiB;
    image = rescueRelease.image;
  };
}
