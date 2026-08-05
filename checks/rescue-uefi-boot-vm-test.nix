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
#      -- `nixrescue-resolve-slot`, an ordered `boot.initrd.systemd.services`
#      oneshot below (systemd stage 1 has no `postDeviceCommands` -- see the
#      note on that migration further down), reads /EFI/nixrescue/current
#      and either honours it or falls back to probing in order. Both
#      scenarios in this file are real, separate boots of two genuinely
#      different disks, not two branches of the same script:
#      "pointer-honoured" points at a slot that would NOT be picked by naive
#      first-available probing, and "fallback-on-bad-pointer" names a slot
#      with a deliberately invalid superblock. Either one, if the resolver
#      silently ignored the pointer/fallback logic, would mount the WRONG
#      device -- caught by `findmnt`, not by trusting a log line.
#   3. mounts that slot's squashfs read-only            -- `mount -t
#      squashfs`, no loop device (see the note on `loop` below).
#   4. overlays tmpfs over it                           -- a real overlayfs
#      mount, proven writable (not just rendered).
#   5. switch_root into a working system reaching multi-user.target, with
#      the Nix database actually populated (not an empty sqlite file that
#      happens to sit next to a working store).
#
# SYSTEMD STAGE 1. This node boots with `boot.initrd.systemd.enable = true`
# (this option's own upstream default at the revision this repo pins) --
# scripted stage 1 is deprecated and scheduled for removal in NixOS 26.11, the
# release this repo already tracks. `nixrescue-resolve-slot` (below) is the
# `postDeviceCommands` replacement -- an ordered oneshot unit, since classic
# stage 1's hook has no systemd-stage-1 equivalent at all (NixOS's own
# assertion for it says so directly) -- and the three mounts below are raw
# `boot.initrd.systemd.mounts` entries rather than `fileSystems.*`, so the
# ordering between them is a real `after`/`requires` edge in the unit graph,
# not whatever order a classic stage-1 script happened to mount things in.
# Same shape as `../examples/rescue/overlay-store.nix`; see that file's own
# header for the full reasoning, copied here rather than re-derived.
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
# `lib.mkMaintainer` and this test intentionally use the same NixOS
# `make-squashfs.nix` implementation. It keeps store paths flat at the image
# root and emits `nix-path-registration`, exactly what the `/nix/.ro-store`
# overlay expects. This test builds the image directly only to keep the VM's
# boot assembly isolated from the host-side timer wrapper.
#
# WHY nixboot.enable STAYS AT ITS DEFAULT (false) on the booted node, while
# `nixboot.extraEntries.rescue` is still declared: `system.build.
# extraEntryMaintainers` is exposed UNCONDITIONALLY (nixboot's own
# extra-entries.nix docstring: "same reason [the source pipeline] exposes
# its maintainer script outside its own active-gate"), but wiring the
# maintainer script into `environment.systemPackages` -- which
# `nixboot.enable = true` would do -- happens INSIDE the same evaluation as
# this node's own `config.system.build.toplevel`, and that script's own
# `text` embeds `${entry.toplevel}`, i.e. `${config.system.build.toplevel}`
# itself. Self-reference through `environment.systemPackages` into the very
# derivation being defined is a real infinite regress, not a style
# preference -- so the UKI is built by a SEPARATE, throwaway `eval-config.nix`
# evaluation below (`ukiEval`), which only ever CONSUMES this node's toplevel
# as a plain value, never feeds back into it.
#
# NOT TESTED HERE, on purpose (see rescue-vm-test.nix for all of these):
# the nixfs repair toolchain, the GUI raise-on-demand pointer, vault
# unlock, and the synthetic-broken-disk recovery path. This file's entire
# job is the boot chain in front of all of that. Also not tested, and never
# testable in a VM: firmware binding to a real GPU/radio -- this project's
# design record's own accepted gap, closed by one supervised human boot per
# physical target instead (docs/design.md, "Testing philosophy").

{ pkgs, lib, nixpkgs, nixrescueModule, nixbootModule }:

let
  # nixboot.nix writes `boot.lanzaboote.enable`/`.bootCounting.initialTries`
  # unconditionally inside its OWN `mkIf cfg.enable` block, which never fires
  # here (`nixboot.enable` stays at its default `false` on the UKI-builder
  # eval below is NOT true -- see next paragraph) -- but nixboot's own test
  # suite (nixboot/checks/default.nix) always composes this stand-in
  # regardless, and it costs nothing to match that convention defensively.
  fakeLanzabooteModule =
    { lib, ... }:
    {
      options.boot.lanzaboote = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        pkiBundle = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        bootCounting.initialTries = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
        };
      };
    };

  makeSquashfs = pkgs.callPackage (nixpkgs + "/nixos/lib/make-squashfs.nix");

  testPointerHonouredSlot = "slot-b";
  testFallbackPointerSlot = "slot-a"; # names the slot this file leaves corrupted

  espFileName = "nixrescue-test.efi";
in
pkgs.testers.nixosTest {
  name = "nixrescue-uefi-boot-and-slot-selection";

  nodes.machine =
    { config, lib, utils, ... }:
    let
      # Same three paths (and the same escapeSystemdPath-derived unit names) as
      # `../examples/rescue/overlay-store.nix` -- see that file's own header for the reasoning.
      roStoreMount = "/sysroot/nix/.ro-store";
      rwStoreMount = "/sysroot/nix/.rw-store";
      nixStoreMount = "/sysroot/nix/store";
      roStoreUnit = "${utils.escapeSystemdPath roStoreMount}.mount";
      rwStoreUnit = "${utils.escapeSystemdPath rwStoreMount}.mount";
      nixStoreUnit = "${utils.escapeSystemdPath nixStoreMount}.mount";

      # ── The UKI, built via nixboot's OWN extraEntries pipeline ───────────
      # A separate, throwaway nixosConfiguration -- NOT this node's own
      # module list -- purely so `nixboot.extraEntries.rescue.toplevel` can
      # point at THIS node's `config.system.build.toplevel` as a plain
      # value without ever feeding back into it (see this file's own header
      # for why that distinction matters).
      #
      # nixboot's maintainer script writes to `${esp.mountPoint}/EFI/Linux/`
      # (default mountPoint "/boot") when actually RUN, below, inside a
      # `pkgs.runCommand` -- the Nix build sandbox's own "/" is not
      # writable, but "/tmp" (bind-mounted from the builder's own TMPDIR) is,
      # so this points mountPoint there instead of the real ESP path a live
      # host would use.
      ukiEspMountPoint = "/tmp/nixrescue-esp-staging";
      ukiEval =
        (import (nixpkgs + "/nixos/lib/eval-config.nix") {
          system = "x86_64-linux";
          modules = [
            nixbootModule
            fakeLanzabooteModule
            {
              nixboot.enable = true;
              # "none": a foreign ESP this module is only allowed to add ONE
              # entry to -- exactly nixrescue's own agnostic-main scenario
              # (design record §2), and the same fixture
              # (`cfg-none-unsigned`) nixboot's own checks/default.nix
              # already exercises for extraEntries.
              nixboot.loader.program = "none";
              # No Secure Boot anywhere on this test host -- the task this
              # harness was built for is explicit that the unsigned path is
              # the correct one here, and nixboot decouples sign.enable from
              # secureBoot.enable precisely so this is a complete, working
              # answer on its own (extra-entries.nix's own `sign.enable`
              # option doc).
              nixboot.secureBoot.sbctlCompat = false;
              nixboot.verify.enable = false; # verifies a live ESP mount this throwaway eval never has
              nixboot.esp.mountPoint = ukiEspMountPoint;
              nixboot.extraEntries.rescue = {
                toplevel = config.system.build.toplevel;
                inherit espFileName;
                sign.enable = false;
                rotate = false;
                bootEntry.enable = false;
              };
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = lib.trivial.release;
            }
          ];
        }).config;

      ukiMaintainer = ukiEval.system.build.extraEntryMaintainers.rescue;

      # nixboot's maintainer script places the UKI at
      # <esp.mountPoint>/EFI/Linux/<espFileName> (default mountPoint "/boot")
      # -- the standard systemd-boot-family auto-discovery location. This
      # test's own ESP carries no NVRAM entries and no systemd-boot to do
      # that discovery; it relocates the built UKI to the UEFI REMOVABLE
      # fallback path instead (\EFI\BOOT\BOOTX64.EFI), which is what makes
      # it bootable with a completely fresh, entry-less firmware NVRAM every
      # single run. A production host that owns its own ESP would leave it
      # at nixboot's own EFI/Linux path; this relocation is this test's own
      # assembly step, not a change to nixboot's mechanism.
      builtUki = pkgs.runCommand "nixrescue-test-uki" { } ''
        mkdir -p "${ukiEspMountPoint}"
        ${lib.getExe ukiMaintainer}
        cp "${ukiEspMountPoint}/EFI/Linux/${espFileName}" $out
      '';

      # ── The rescue's own squashfs, WITH the nix-path-registration
      #    manifest baked in by the same closureInfo make-squashfs.nix
      #    always uses -- copied pattern, not invented (see this file's
      #    own header). Cheap compression: this is a disposable test
      #    build, not the production artifact (docs/design.md's own
      #    level-22 measurement is about the real image, not this one).
      rescueSquashfs = makeSquashfs {
        storeContents = [ config.system.build.toplevel ];
        comp = "zstd -Xcompression-level 3";
      };

      # ── The synthetic disk: one ESP + two raw slot partitions ────────────
      # Single virtio-blk disk -> deterministic /dev/vda1 (ESP) /vda2
      # (slot-a) /vda3 (slot-b) partition numbering, so the initrd's own
      # resolver service (nixrescue-resolve-slot, below) never needs blkid or
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
              # slot-a's region is deliberately left exactly as `truncate`
              # made it: a sparse hole, i.e. all zero bytes -- not a valid
              # squashfs superblock. This is the point of this scenario: it
              # proves the initrd's fallback path, not a hand-picked
              # "corruption" byte pattern standing in for one.
              echo "nixrescue test disk (${name}): slot-a left zero-filled on purpose (invalid superblock)" 1>&2
            ''}
            dd if=${rescueSquashfs} of=disk.img bs=512 seek="$p3" conv=notrunc status=none

            mkdir -p $out
            mv disk.img $out/disk.img
          '';
    in
    {
      imports = [ nixrescueModule ];

      nixrescue = {
        enable = true;
        builtAt = "2026-07-28T00:00:00Z";
        authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test-operator-key" ];
      };

      # Smaller, faster closure -- this test's whole point is the boot
      # chain, not documentation.
      documentation.enable = false;
      documentation.nixos.enable = false;

      # ── real UEFI firmware, a real disk, no host-store sharing ──────────
      # This exact combination (useEFIBoot without useBootLoader,
      # directBoot.enable = false, mountHostNixStore = false,
      # virtualisation.fileSystems forced empty so THIS module's own
      # fileSystems below are what actually apply) is copied from nixpkgs'
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
      # file's own `nixrescue-register-nix-paths` (below) is the one doing
      # the real work.
      systemd.services.register-nix-paths.enable = false;

      # ── THE OVERLAY MECHANISM (copied, see this file's own header) ─────
      fileSystems."/" = {
        fsType = "tmpfs";
        device = "none";
        options = [ "mode=0755" ];
      };

      # This option's own upstream default at the revision this repo pins --
      # stated explicitly because every service and mount below depends on
      # it, not to restate a default for its own sake. See this file's own
      # header ("SYSTEMD STAGE 1") and `../examples/rescue/overlay-store.nix`
      # for the full reasoning behind this migration.
      boot.initrd.systemd.enable = true;

      boot.initrd.availableKernelModules = [
        "squashfs"
        "vfat"
        "nls_cp437"
        "nls_iso8859_1"
      ];
      # "overlay" force-loaded (no "loop" -- see this file's own header on
      # why a raw-partition slot needs none).
      boot.initrd.kernelModules = [ "overlay" ];

      # ── slot resolution: the postDeviceCommands replacement ─────────────
      # Same ordering idiom as `../examples/rescue/overlay-store.nix`'s own
      # `nixrescue-resolve-slot` (copied pattern, see that file's own
      # comment for the ZFS-import-service precedent) -- this test's own
      # resolver differs only in WHICH devices it looks at: fixed
      # /dev/vda1/vda2/vda3 rather than by-label/by-partlabel, exactly as
      # the classic-stage-1 version of this same test used before this
      # migration (see this file's own header on why the two resolvers have
      # never been byte-identical).
      boot.initrd.systemd.services.nixrescue-resolve-slot = {
        description = "nixrescue: resolve which cold-mode slot to boot from";
        unitConfig.DefaultDependencies = false;
        requiredBy = [ roStoreUnit ];
        before = [ roStoreUnit "shutdown.target" ];
        conflicts = [ "shutdown.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          echo "nixrescue: resolving which cold-mode slot to boot from"
          mkdir -p /mnt-esp /mnt-slot-test

          pointer=""
          if mount -t vfat -o ro /dev/vda1 /mnt-esp 2>/dev/null; then
            if [ -r /mnt-esp/EFI/nixrescue/current ]; then
              pointer=$(cat /mnt-esp/EFI/nixrescue/current 2>/dev/null | tr -d ' \t\r\n') || true
            fi
            umount /mnt-esp 2>/dev/null || true
          else
            echo "nixrescue: warning: could not mount the ESP to read the pointer file" >&2
          fi

          # "a slot is a valid superblock or it is not" -- the check IS the
          # mount attempt, not a magic-number parse.
          trySlot() {
            mount -t squashfs -o ro "$1" /mnt-slot-test 2>/dev/null || return 1
            umount /mnt-slot-test 2>/dev/null || true
            return 0
          }

          candidate=""
          case "$pointer" in
            slot-a) candidate=/dev/vda2 ;;
            slot-b) candidate=/dev/vda3 ;;
            "") echo "nixrescue: no pointer file found on the ESP -- probing in order" ;;
            *) echo "nixrescue: pointer names an unrecognised slot '$pointer' -- probing in order" ;;
          esac

          chosen=""
          if [ -n "$candidate" ]; then
            if trySlot "$candidate"; then
              chosen="$candidate"
              echo "nixrescue: pointer names '$pointer' ($candidate) -- honoured"
            else
              echo "nixrescue: pointer names '$pointer' ($candidate) but its superblock check FAILED -- falling back to probing"
            fi
          fi

          if [ -z "$chosen" ]; then
            for dev in /dev/vda2 /dev/vda3; do
              if trySlot "$dev"; then
                chosen="$dev"
                echo "nixrescue: probing found a usable slot at $dev"
                break
              fi
            done
          fi

          if [ -z "$chosen" ]; then
            echo "nixrescue: FATAL: no usable rescue slot found on any device" >&2
          else
            ln -sf "$chosen" /dev/nixrescue-active-slot
            echo "nixrescue: active slot -> $chosen"
          fi
        '';
      };

      # NixOS's stage 2 unconditionally self-bind-remounts /nix/store with
      # `boot.nixStoreMountOpts` (default `["ro" "nodev" "nosuid"]`,
      # nixos/modules/system/boot/stage-2-init.sh) as a store-immutability
      # hardening feature completely UNRELATED to this project's own overlay
      # -- and it applies regardless of what actually backs /nix/store, and
      # regardless of which stage-1 flavour built it (stage 2 is the SAME
      # activation payload either way). Left at its default, this is exactly
      # what turned the writable overlay this test sets up into a second,
      # read-only bind mount stacked on top of it (found empirically:
      # `findmnt` showed the SAME /nix/store target mounted twice, the
      # second one "ro,nosuid,nodev"). A rescue image's whole point is a
      # writable overlay, so this host opts out of the immutability
      # hardening rather than fighting it.
      boot.nixStoreMountOpts = [ ];

      # ── the overlay mounts themselves: explicit units, explicit ordering ─
      # Raw `boot.initrd.systemd.mounts` entries, not `fileSystems.*` --
      # same shape and same reasoning as
      # `../examples/rescue/overlay-store.nix`'s own mounts list (see that
      # file's own comment on why `where` therefore carries the literal
      # `/sysroot` prefix, and why the overlay mount needs an explicit
      # `after`/`requires` on the other two rather than relying on
      # systemd's implicit mount-nesting).
      boot.initrd.systemd.mounts = [
        {
          # No by-label/by-partlabel device here: WHICH slot backs this is
          # resolved at boot by nixrescue-resolve-slot above, which points
          # this at a fixed symlink it creates once slot selection is done
          # -- exactly the pattern LUKS/LVM's own device-mapper nodes
          # already rely on (a stable logical name, populated before the
          # mount unit that consumes it runs).
          where = roStoreMount;
          what = "/dev/nixrescue-active-slot";
          type = "squashfs";
          options = "ro";
        }
        {
          where = rwStoreMount;
          what = "tmpfs";
          type = "tmpfs";
          options = "mode=0755";
        }
        {
          where = nixStoreMount;
          what = "overlay";
          type = "overlay";
          options = "lowerdir=${roStoreMount},upperdir=${rwStoreMount}/store,workdir=${rwStoreMount}/work";
          after = [ roStoreUnit rwStoreUnit ];
          requires = [ roStoreUnit rwStoreUnit ];
          # The one unit here actually pulled into the boot transaction by
          # name; ro-store and rw-store above are pulled in transitively
          # through THIS unit's own `requires` immediately above.
          requiredBy = [ "initrd-fs.target" ];
          before = [ "initrd-fs.target" ];
        }
      ];

      # overlayfs needs its upperdir/workdir to exist before the overlay
      # mount is attempted -- same shape as
      # `../examples/rescue/overlay-store.nix`'s own
      # `nixrescue-prepare-overlay-dirs` (itself copied from NixOS's own
      # `preMountService` in `nixos/modules/tasks/filesystems/overlayfs.nix`).
      boot.initrd.systemd.services.nixrescue-prepare-overlay-dirs = {
        description = "nixrescue: create the overlay's upper/work directories inside the rw store";
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = rwStoreMount;
        };
        requiredBy = [ nixStoreUnit ];
        before = [ nixStoreUnit "shutdown.target" ];
        conflicts = [ "shutdown.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/mkdir -p -m 0755 ${rwStoreMount}/store ${rwStoreMount}/work";
        };
      };

      # ── THE NIX DATABASE (copied pattern, see this file's own header) ──
      systemd.services.nixrescue-register-nix-paths = {
        description = "nixrescue: load the Nix database baked inside the squashfs";
        unitConfig.DefaultDependencies = false;
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
          "nix-daemon.socket"
          "nix-daemon.service"
        ];
        after = [ "local-fs.target" ];
        conflicts = [ "shutdown.target" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix/store/nix-path-registration
        '';
      };

      system.build.testDiskPointerHonoured = mkTestDisk {
        name = "pointer-honoured";
        pointerValue = testPointerHonouredSlot; # "slot-b" -- NOT what naive probing would find first
        corruptSlotA = false;
      };
      system.build.testDiskFallback = mkTestDisk {
        name = "fallback";
        pointerValue = testFallbackPointerSlot; # "slot-a" -- the one this disk corrupts
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

      with subtest("scenario 1: pointer honoured (names slot-b, which naive first-available probing would NOT pick)"):
          boot_with(disk_pointer_honoured, "nixrescue-test-disk-pointer-honoured.img")
          assert_real_boot_chain("/dev/vda3")
          machine.shutdown()

      with subtest("scenario 2: fallback on a bad pointer (names slot-a, which this disk left with an invalid superblock)"):
          boot_with(disk_fallback, "nixrescue-test-disk-fallback.img")
          assert_real_boot_chain("/dev/vda3")
    '';
}
