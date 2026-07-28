# checks/default.nix
#
# Wires this project's two test files into `nix flake check`:
#   eval-tests.nix     -- rendering-only, no VM, no build beyond the cheap
#                          derivations the module and lib.mkMaintainer
#                          themselves produce.
#   rescue-vm-test.nix -- the real `pkgs.testers.nixosTest`: boots an
#                          actual VM and exercises the boot contract, the
#                          nixfs toolchain, the GUI pointer, disk recovery
#                          and materialisation end to end. See that file's
#                          own header for why this exists and what it
#                          deliberately does not cover yet.

{ pkgs, lib, nixpkgs, system, nixrescueModule, nixfsModule, mkMaintainer }:

{
  eval-tests = import ./eval-tests.nix {
    inherit pkgs nixpkgs nixrescueModule mkMaintainer;
  };

  rescue-vm-test = import ./rescue-vm-test.nix {
    inherit pkgs nixpkgs nixrescueModule nixfsModule mkMaintainer;
  };
}
