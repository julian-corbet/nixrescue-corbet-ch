# checks/rescue-uefi-boot-vm-test.nix
#
# THE OTHER HALF OF "boots". rescue-vm-test.nix boots this project's own
# NixOS configuration DIRECTLY -- no firmware, no ESP, no UKI -- and proves
# the module surface and the maintenance mechanism. It deliberately does NOT
# touch the boot chain itself (see its own header). This file is that boot
# chain: real OVMF UEFI firmware, via nixpkgs' own
# `virtualisation.useEFIBoot`/`virtualisation.directBoot.enable = false`
# (nixpkgs' nixos/tests/qemu-vm-external-disk-image.nix is the house
# reference this file's disk-substitution technique copies verbatim: build
# a disk image as its own derivation, then swap it in for the VM's disk via
# the `NIX_DISK_IMAGE` environment variable from inside the testScript,
# which is exactly the supported way to hand a nixosTest node a fully
# custom, pre-built disk instead of letting the qemu-vm module install one).
#
# THE CHAIN THIS ASSERTS, link by link, each with its own failure mode if
# faked or skipped:
#   1. firmware loads a UKI from an ESP               -- no NVRAM entries are
#      ever written on this disk; the UKI is placed at the UEFI REMOVABLE-
#      MEDIA fallback path, \EFI\BOOT\BOOTX64.EFI, which is what
#      `nixboot.esp.efiVariables = "removable"` documents as "boots on any
#      spare box regardless of what is already in NVRAM" -- exactly this
#      test's situation (a fresh OVMF vars store, every run).
#   2. the initrd resolves WHICH slot to boot from a pointer file on the ESP
#      -- `nixrescue-resolve-slot`, the production overlay module's ordered initrd oneshot
#      (systemd stage 1 has no `postDeviceCommands` -- see the
#      note on that migration further down), reads /EFI/nixrescue/current
#      and either honours it or falls back to probing in order. Both
#      scenarios in this file are real, separate boots of two genuinely
#      different disks, not two branches of the same script:
#      "pointer-honoured" points at a slot that would NOT be picked by naive
#      first-available probing, and "fallback-on-bad-pointer" names a slot
#      with a deliberately altered digest but valid superblock. Either one, if the resolver
#      silently ignored the pointer/fallback logic, would mount the WRONG
#      device -- caught by `findmnt`, not by trusting a log line.
#   3. hashes the signed byte range, then mounts it read-only -- no unauthenticated squashfs
#      reaches the kernel parser and no loop device is involved.
#   4. overlays tmpfs over it                           -- a real overlayfs
#      mount, proven writable (not just rendered).
#   5. switch_root into a working system reaching multi-user.target, with
#      the Nix database actually populated (not an empty sqlite file that
#      happens to sit next to a working store).
#
# SYSTEMD STAGE 1. This node boots with `boot.initrd.systemd.enable = true`
# (this option's own upstream default at the revision this repo pins) --
# scripted stage 1 is deprecated and scheduled for removal in NixOS 26.11, the
# release this repo already tracks. `nixrescue-resolve-slot` in the imported overlay module is the
# `postDeviceCommands` replacement -- an ordered oneshot unit, since classic
# stage 1's hook has no systemd-stage-1 equivalent at all (NixOS's own
# assertion for it says so directly) -- and its three mounts are raw
# `boot.initrd.systemd.mounts` entries rather than `fileSystems.*`, so the
# ordering between them is a real `after`/`requires` edge in the unit graph,
# not whatever order a classic stage-1 script happened to mount things in.
# The test imports that mechanism directly rather than maintaining a test-only copy.
#
# THE OVERLAY MECHANISM IS NOT INVENTED HERE. It is NixOS's own live-media
# machinery, copied from `nixos/modules/installer/cd-dvd/iso-image.nix`
# (`config.lib.isoFileSystems`) and `nixos/lib/make-squashfs.nix` verbatim:
# the same `/nix/.ro-store` (squashfs) + `/nix/.rw-store` (tmpfs) + overlay
# `/nix/store` shape, the same `nix-path-registration` file baked into the
# squashfs by the same `closureInfo`-driven `make-squashfs.nix`, and the same
# "oneshot before nix-daemon.socket/.service, after local-fs.target" ordering
# `nix-store --load-db` unit iso-image.nix itself uses (and which
# `nixos/modules/virtualisation/qemu-vm.nix` ALSO uses, independently, for
# its own regInfo=-on-the-kernel-cmdline flavour of the identical idea --
# this project's own version reads a fixed file instead, since our cmdline
# is baked into a UKI, not appended by qemu at direct-boot time).
#
# ONE DELIBERATE DEPARTURE FROM THE LITERAL iso-image.nix SNIPPET: no `loop`
# kernel module, and squashfs is mounted straight off a raw partition/device
# symlink, never a file. The ISO needs `-o loop` because its squashfs is a
# FILE sitting inside an iso9660 filesystem. This project's own design
# record (docs/design.md, "Medium layout") is explicit that a slot is "no
# containing filesystem... mount -t squashfs reads it straight off the block
# device" -- so dropping `loop` here is fidelity to nixrescue's OWN design,
# not a shortcut against the ISO module's.
#
# `lib.mkRelease` and this test intentionally use the same NixOS
# `make-squashfs.nix` implementation. It keeps store paths flat at the image
# root and emits `nix-path-registration`, exactly what the `/nix/.ro-store`
# overlay expects. This test builds the image directly only to keep the VM's
# boot assembly isolated from host-side reconciliation.
#
# NOT TESTED HERE, on purpose (see rescue-vm-test.nix for all of these):
# the nixfs repair toolchain, the GUI raise-on-demand pointer, vault
# unlock, and the synthetic-broken-disk recovery path. This file's entire
# job is the boot chain in front of all of that. Also not tested, and never
# testable in a VM: firmware binding to a real GPU/radio -- this project's
# design record's own accepted gap, closed by one supervised human boot per
# physical target instead (docs/design.md, "Testing philosophy").

{ pkgs, lib, nixpkgs, nixrescueModule, overlayStoreModule, mkUki }:

let
  testPointerHonouredSlot = "nixrescue-b";
  testFallbackPointerSlot = "nixrescue-a"; # names the slot this file leaves corrupted

in
pkgs.testers.nixosTest {
  name = "nixrescue-uefi-boot-and-slot-selection";

  nodes.machine =
    { config, lib, ... }:
    let
      # ── The rescue's own squashfs, WITH the nix-path-registration
      #    manifest baked in by the same closureInfo make-squashfs.nix
      #    always uses -- copied pattern, not invented (see this file's
      #    own header). Cheap compression: this is a disposable test
      #    build, not the production artifact (docs/design.md's own
      #    level-22 measurement is about the real image, not this one).
      rescueSquashfs = pkgs.callPackage (nixpkgs + "/nixos/lib/make-squashfs.nix") {
        storeContents = [ config.system.build.toplevel ];
        comp = "zstd -Xcompression-level 3";
      };

      imageKernelParams = pkgs.runCommand "nixrescue-test-image-kernel-params" { } ''
        image_hash=$(sha256sum ${rescueSquashfs} | cut -d' ' -f1)
        image_size=$(stat -c%s ${rescueSquashfs})
        printf 'nixrescue.imageSha256=%s nixrescue.imageSize=%s\n' \
          "$image_hash" "$image_size" > "$out"
      '';

      # This is nixboot's production library primitive. The raw image digest and length are
      # embedded in the UKI command line before firmware loads it; the initrd below proves those
      # authenticated values control which external squashfs is ever mounted.
      builtUki = mkUki {
        inherit pkgs;
        name = "nixrescue-test";
        toplevel = config.system.build.toplevel;
        kernelParamFiles = [ imageKernelParams ];
      };

      # ── The synthetic disk: one ESP + two raw slot partitions ────────────
      # Single virtio-blk disk -> deterministic /dev/vda1 (ESP) /vda2
      # (slot-a) /vda3 (slot-b) partition numbering, so the initrd's own
      # resolver service never needs blkid or
      # partlabel lookups to find them.
      mkTestDisk =
        { name, pointerValue, corruptSlotA }:
        pkgs.runCommand "nixrescue-test-disk-${name}"
          {
            nativeBuildInputs = [
              pkgs.gptfdisk
              pkgs.dosfstools
              pkgs.mtools
              pkgs.gawk
              pkgs.coreutils
            ];
          }
          ''
            set -euo pipefail

            espSizeMiB=$(( ( $(stat -c%s ${builtUki}) / 1048576 ) + 16 ))
            slotSizeMiB=$(( ( $(stat -c%s ${rescueSquashfs}) / 1048576 ) + 16 ))

            truncate -s "''${espSizeMiB}MiB" esp.img
            mkfs.vfat -F32 -n NIXRESCUE esp.img
            mmd -i esp.img ::EFI
            mmd -i esp.img ::EFI/BOOT
            mmd -i esp.img ::EFI/nixrescue
            mcopy -i esp.img ${builtUki} ::EFI/BOOT/BOOTX64.EFI
            printf '%s' "${pointerValue}" > pointer-file
            mcopy -i esp.img pointer-file ::EFI/nixrescue/current

            diskSizeMiB=$(( 2 + espSizeMiB + slotSizeMiB + slotSizeMiB ))
            truncate -s "''${diskSizeMiB}MiB" disk.img

            sgdisk -o disk.img
            sgdisk -n "1:0:+''${espSizeMiB}MiB" -t 1:ef00 -c 1:NIXRESCUE-ESP disk.img
            sgdisk -n "2:0:+''${slotSizeMiB}MiB" -t 2:8300 -c 2:nixrescue-a disk.img
            sgdisk -n "3:0:+''${slotSizeMiB}MiB" -t 3:8300 -c 3:nixrescue-b disk.img
            sgdisk -p disk.img 1>&2

            p1=$(sgdisk -i 1 disk.img | awk '/^First sector:/ {print $3}')
            p2=$(sgdisk -i 2 disk.img | awk '/^First sector:/ {print $3}')
            p3=$(sgdisk -i 3 disk.img | awk '/^First sector:/ {print $3}')

            dd if=esp.img of=disk.img bs=512 seek="$p1" conv=notrunc status=none

            ${lib.optionalString (!corruptSlotA) ''
              dd if=${rescueSquashfs} of=disk.img bs=512 seek="$p2" conv=notrunc status=none
            ''}
            ${lib.optionalString corruptSlotA ''
              # Keep a structurally valid squashfs with the expected init pathname, but alter one
              # padding byte covered by the signed digest. Pathname/superblock probing would accept
              # it; cryptographic image binding must reject it before mount.
              cp --no-preserve=mode ${rescueSquashfs} corrupted-slot-a
              image_size=$(stat -c%s corrupted-slot-a)
              printf '\001' | dd of=corrupted-slot-a bs=1 seek="$((image_size - 1))" conv=notrunc status=none
              dd if=corrupted-slot-a of=disk.img bs=512 seek="$p2" conv=notrunc status=none
              echo "nixrescue test disk (${name}): slot-a has a valid superblock but a wrong signed digest" 1>&2
            ''}
            dd if=${rescueSquashfs} of=disk.img bs=512 seek="$p3" conv=notrunc status=none

            mkdir -p $out
            mv disk.img $out/disk.img
          '';
    in
    {
      imports = [ nixrescueModule overlayStoreModule ];

      nixrescue = {
        enable = true;
        authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test-operator-key" ];
        ssh = {
          enable = true;
          # This VM proves the real UEFI/stub/slot handoff but does not emulate a TPM-sealed
          # credential. Production leaves this at true; the separate eval contract proves the
          # strict LoadCredentialEncrypted/no-host-key-fallback wiring.
          tpm2Credential = false;
        };
        store = {
          slotDevices = [ "/dev/vda2" "/dev/vda3" ];
          espDevice = "/dev/vda1";
        };
      };

      # Smaller, faster closure -- this test's whole point is the boot
      # chain, not documentation.
      documentation.enable = false;
      documentation.nixos.enable = false;

      # ── real UEFI firmware, a real disk, no host-store sharing ──────────
      # This exact combination (useEFIBoot without useBootLoader,
      # directBoot.enable = false, mountHostNixStore = false,
      # virtualisation.fileSystems forced empty so the imported overlay module's own
      # fileSystems are what actually apply) is copied from nixpkgs'
      # own nixos/tests/qemu-vm-external-disk-image.nix -- the house
      # reference for "boot a nixosTest node off a disk image this module
      # didn't build itself".
      virtualisation.useEFIBoot = true;
      virtualisation.directBoot.enable = false;
      virtualisation.mountHostNixStore = false;
      virtualisation.fileSystems = lib.mkForce { };
      # virtualisation.useSecureBoot already defaults to false, which is what
      # this test needs (the UKI above is unsigned) -- left at its default
      # rather than restated.
      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;

      # qemu-vm.nix's OWN register-nix-paths unit reads a `regInfo=` kernel
      # command-line parameter that only ever gets appended by the
      # DIRECT-boot `-append` string (directBoot.enable = false, above,
      # means that string is never constructed at all). Left enabled it
      # would just be a permanent, harmless no-op every boot; disabled
      # explicitly so a reader isn't left wondering whether it or this
      # imported overlay module's `nixrescue-register-nix-paths` is the one doing the real work.
      systemd.services.register-nix-paths.enable = false;

      system.build.testDiskPointerHonoured = mkTestDisk {
        name = "pointer-honoured";
        pointerValue = testPointerHonouredSlot; # nixrescue-b -- NOT what naive probing would find first
        corruptSlotA = false;
      };
      system.build.testDiskFallback = mkTestDisk {
        name = "fallback";
        pointerValue = testFallbackPointerSlot; # nixrescue-a -- the one this disk corrupts
        corruptSlotA = true;
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import os
      import shutil

      toplevel = "${nodes.machine.system.build.toplevel}"
      disk_pointer_honoured = "${nodes.machine.system.build.testDiskPointerHonoured}/disk.img"
      disk_fallback = "${nodes.machine.system.build.testDiskFallback}/disk.img"

      tmp_dir = os.environ.get("TMPDIR", "/tmp")

      def boot_with(disk_path, tmp_name):
          tmp_disk = os.path.join(tmp_dir, tmp_name)
          shutil.copy(disk_path, tmp_disk)
          os.chmod(tmp_disk, 0o600)
          os.environ["NIX_DISK_IMAGE"] = tmp_disk
          machine.start()

      def assert_real_boot_chain(expected_slot_device):
          machine.wait_for_unit("multi-user.target")

          with subtest("switch_root landed in a working system: sshd is up with the operator key installed"):
              machine.wait_for_unit("sshd.service")
              machine.succeed("systemctl is-active sshd.service")
              machine.succeed("grep -q test-operator-key /etc/ssh/authorized_keys.d/root")

          with subtest("the rescue reports the release identity authenticated by its UKI"):
              release_info = machine.succeed("nixrescue-release-info")
              cmdline = machine.succeed("cat /proc/cmdline")
              values = dict(line.split("=", 1) for line in release_info.strip().splitlines())
              assert f"nixrescue.imageSha256={values['image-sha256']}" in cmdline, release_info
              assert f"nixrescue.imageSize={values['image-size']}" in cmdline, release_info
              assert values["init"] == f"{toplevel}/init", release_info

          with subtest("the resolved slot is the one this scenario expects, not merely 'some' slot"):
              # `findmnt --target` reports one line per stacked mount at that
              # path (systemd's stage-2 unit remounting what the initrd
              # already handed over across switch_root is a normal, harmless
              # NixOS pattern here) -- the topmost (first) line is the
              # authoritative, currently-active one.
              src = machine.succeed(
                  "findmnt -no SOURCE --target /nix/.ro-store"
              ).strip().splitlines()[0]
              assert src == expected_slot_device, (
                  f"expected /nix/.ro-store mounted from {expected_slot_device}, "
                  f"findmnt reported: {src}"
              )

          with subtest("the lower store is genuinely read-only, not just labelled so"):
              machine.fail("touch /nix/.ro-store/nixrescue-ro-probe")

          with subtest("the overlay is real: /nix/store is overlayfs, and genuinely writable"):
              fstype = machine.succeed(
                  "findmnt -no FSTYPE --target /nix/store"
              ).strip().splitlines()[0]
              assert fstype == "overlay", f"expected /nix/store to be an overlay mount, got fstype={fstype}"
              machine.succeed(
                  "touch /nix/store/nixrescue-overlay-write-probe "
                  "&& rm /nix/store/nixrescue-overlay-write-probe"
              )

          with subtest("the Nix database was actually loaded from the baked-in registration, not left empty"):
              out = machine.succeed(f"nix-store --query --references {toplevel}")
              assert out.strip() != "", "nix-store -q --references returned nothing -- the DB load-db step did not run (or the store is unregistered)"

      with subtest("scenario 1: pointer honoured (names nixrescue-b, which naive first-available probing would NOT pick)"):
          boot_with(disk_pointer_honoured, "nixrescue-test-disk-pointer-honoured.img")
          assert_real_boot_chain("/dev/vda3")
          machine.shutdown()

      with subtest("scenario 2: fallback on a bad pointer (names nixrescue-a, whose valid squashfs has the wrong signed digest)"):
          boot_with(disk_fallback, "nixrescue-test-disk-fallback.img")
          assert_real_boot_chain("/dev/vda3")
    '';
}
