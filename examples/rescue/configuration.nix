# examples/rescue/configuration.nix
#
# THE FIRST REAL, GENERIC `nixosConfigurations.rescue` -- an EXAMPLE, not a host. Per this project's
# own sealed design record, the rescue image is IDENTICAL across every machine it sits in front of:
# identity comes from a vault at boot, never from this image. So nothing here names a hostname, a
# NetBird key, an SSH host key, or any other per-machine fact -- a real consumer's own flake wires
# THIS shape (nixrescue's module, the repair toolchain, curated firmware, the overlay store) plus
# whatever per-host boot-entry signing a boot-arbitration module contributes on top, unchanged
# across every host that substitutes it.
#
# Composed here, each doing exactly what it already does elsewhere in this family (see this
# project's own README, "The two things this repo actually is", and nixfs's own module for its
# half):
#   - `nixrescueModule`         -- this project's own runtime contract (sshd, operator keys, the
#                                  optional GUI pointer, an optional vault). See ../../modules/nixrescue.nix.
#   - `nixfsModule`             -- the repair toolchain, pinned from nixpkgs regardless of distro.
#   - `./overlay-store.nix`     -- the squashfs+tmpfs overlay store arrangement a slot boots into.
#   - curated firmware          -- see ../../lib/firmware.nix; wired in below via `hardware.firmware`.
#
{ lib, pkgs, nixfsLib, curatedFirmware, ... }:

{
  nixrescue = {
    enable = true;

    # A real materialisation pipeline stamps this at build time from whatever tool produces the
    # image (see ../../modules/nixrescue.nix's own option doc for why there is deliberately no
    # default). Fixed here only so this EXAMPLE evaluates and builds standalone -- a real consumer
    # overrides it, every build, never reuses this value.
    builtAt = "2026-07-28T00:00:00Z";

    # The operator supplies their own PUBLIC keys; none are baked into an example that ships to
    # every clone of this repo. Empty means console-only until a vault (if one is composed at all,
    # which this example deliberately does not) brings up a real identity -- see
    # ../../modules/nixrescue.nix's own option doc.
    authorizedKeys = [ ];

    # THE COMPOSITOR CHOICE IS STILL OPEN -- deliberately left null, never picked here. Per this
    # project's own module (see its SCOPE comment and the `gui.package` option doc), null means
    # headless-only: multi-user.target with sshd up, nothing raised at the console. This is the
    # headless deliverable; a GUI slots in later through this exact same pointer, unchanged.
    gui.package = null;

    # No vault composed in this generic example -- packing one is nixvault's whole job, kept
    # deliberately apart (see ../../modules/nixrescue.nix's own SCOPE comment). A permanently
    # LAN-only rescue with no fleet identity to unlock is a legitimate, safe choice on its own.
  };

  nixfs = {
    enable = true;
    # Every filesystem the catalogue knows, per nixfs's own README ("For every format at once, use
    # the flake's own list rather than copying one") -- a rescue's whole point is meeting media it
    # has never seen before, so there is no principled way to guess a narrower list here.
    filesystems = nixfsLib.allFilesystems;
    tools.throughput.enable = false; # fio drags in python3 at ~134 MiB -- a rescue booted to
    # recover a disk has no use for drive-throughput benchmarking, only pv's progress display
    # (which stays on, since it lives in a different tool group).
  };

  # sshd itself needs no separate composition here: `nixrescue.enable = true` above already turns
  # on `services.openssh` (see ../../modules/nixrescue.nix) -- restating it would be exactly the
  # kind of option-that-restates-the-name this project's whole house style forbids.

  # ── Firmware: curated, not the whole redistributable set ─────────────────────────────────────
  # See ../../lib/firmware.nix for the reviewable subtree list and the two traps its own header
  # documents. `false` here is load-bearing: leaving `enableRedistributableFirmware` at its default
  # would hand the kernel the ENTIRE upstream package regardless of what `hardware.firmware` also
  # names, since both accumulate into the same option.
  hardware.enableRedistributableFirmware = false;
  hardware.firmware = [ curatedFirmware ];

  # No bootloader here -- registering an ESP entry is a boot-arbitration module's domain, never
  # this project's (see ../../modules/nixrescue.nix's own SCOPE comment). `./overlay-store.nix`
  # already supplies this configuration's actual root filesystem.
  boot.loader.grub.enable = false;

  # Every byte this closure does not need is a byte closer to overflowing a small, fixed slot --
  # and a rescue console has no reader for a man page anyway.
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = lib.trivial.release;
}
