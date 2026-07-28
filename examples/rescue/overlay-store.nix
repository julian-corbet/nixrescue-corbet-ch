# examples/rescue/overlay-store.nix
#
# The squashfs+tmpfs overlay store arrangement this design record's own boot-flow describes: a
# read-only squashfs slot as the lower store, a tmpfs upper store, merged into the ordinary
# `/nix/store` path a switch_root'd system expects. THE MECHANISM IS NOT INVENTED HERE -- it is
# NixOS's own live-media machinery, the same `/nix/.ro-store` (squashfs) + `/nix/.rw-store` (tmpfs)
# + overlay `/nix/store` shape and the same `nix-path-registration`-driven database load
# `nixos/modules/installer/cd-dvd/iso-image.nix` and `nixos/lib/make-squashfs.nix` already use, and
# the exact shape `../../checks/rescue-uefi-boot-vm-test.nix` already proves boots end to end under
# real OVMF UEFI firmware (see that file's own header for the full provenance and for the one
# deliberate departure from the ISO's literal snippet: no `loop` device, because a slot here is a
# raw partition, not a file inside an iso9660 filesystem).
#
# GENERALISED HERE from that test's single hand-built two-slot disk to any medium carrying one or
# more partitions labelled `nixrescue-slot-*`, plus an ESP labelled `NIXRESCUE` carrying an optional
# `/EFI/nixrescue/current` pointer file. "Boot the previous build" is then editing that one file,
# not re-flashing anything -- exactly the slot-selection contract this project's own design record
# states (see docs/design.md, "Medium layout").
#
# WHAT THIS DOES NOT DECIDE: how many slots exist on any given medium, which bootloader placed a UKI
# in front of this, or how bytes got onto the medium in the first place. Those are a boot-arbitration
# module's domain and `lib.mkMaintainer`'s, respectively -- see `../../modules/nixrescue.nix`'s own
# SCOPE comment. This file wires the one thing every consumer needs regardless of slot count:
# resolve which slot to mount, mount it read-only, and overlay a writable tmpfs on top before
# anything else in the boot depends on `/nix/store` existing.
#
# NOT covered by a dedicated test in this repo: this generalised (by-label/by-partlabel) form is a
# straightforward reshaping of the exact mechanism `rescue-uefi-boot-vm-test.nix` already exercises
# against a hand-built two-slot disk -- growing that harness to also drive THIS file's own
# by-partlabel probing loop, rather than the hand-rolled `/dev/vda2`/`/dev/vda3` device names it
# uses today, is the natural next increment (see this project's own testing philosophy, docs/design.md,
# on why the harness is built to grow rather than arrive complete).
#
{ config, lib, ... }:

{
  fileSystems."/" = {
    fsType = "tmpfs";
    device = "none";
    options = [ "mode=0755" ];
  };

  fileSystems."/nix/.ro-store" = {
    # Populated by boot.initrd.postDeviceCommands below, before this mount unit ever runs -- the
    # same stable-symlink-populated-by-initrd pattern LUKS/LVM device-mapper nodes already rely on.
    device = "/dev/nixrescue-active-slot";
    fsType = "squashfs";
    neededForBoot = true;
  };

  fileSystems."/nix/.rw-store" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };

  fileSystems."/nix/store" = {
    overlay = {
      lowerdir = [ "/nix/.ro-store" ];
      upperdir = "/nix/.rw-store/store";
      workdir = "/nix/.rw-store/work";
    };
  };

  boot.initrd.availableKernelModules = [
    "squashfs"
    "vfat"
    "nls_cp437"
    "nls_iso8859_1"
  ];
  # "overlay" force-loaded (no "loop" -- a slot is a raw partition, never a file, see this file's
  # own header).
  boot.initrd.kernelModules = [ "overlay" ];

  # Classic (non-systemd) stage 1, deliberately: `postDeviceCommands` is its hook for exactly this
  # job -- runs after udev has settled and every partition device exists, before `fileSystems` gets
  # mounted (nixos/modules/system/boot/stage-1-init.sh).
  boot.initrd.systemd.enable = false;

  boot.initrd.postDeviceCommands = ''
    echo "nixrescue: resolving which cold-mode slot to boot from"
    mkdir -p /mnt-esp /mnt-slot-probe

    pointer=""
    espDevice=$(blkid -t LABEL=NIXRESCUE -o device 2>/dev/null | head -n1) || true
    if [ -n "$espDevice" ] && mount -t vfat -o ro "$espDevice" /mnt-esp 2>/dev/null; then
      if [ -r /mnt-esp/EFI/nixrescue/current ]; then
        pointer=$(cat /mnt-esp/EFI/nixrescue/current 2>/dev/null | tr -d ' \t\r\n') || true
      fi
      umount /mnt-esp 2>/dev/null || true
    else
      echo "nixrescue: no NIXRESCUE-labelled ESP found (or it would not mount) -- probing slots in order" >&2
    fi

    # "a slot is a valid superblock or it is not" -- the check IS the mount attempt, not a
    # magic-number parse.
    trySlot() {
      mount -t squashfs -o ro "$1" /mnt-slot-probe 2>/dev/null || return 1
      umount /mnt-slot-probe 2>/dev/null || true
      return 0
    }

    chosen=""
    if [ -n "$pointer" ]; then
      candidate="/dev/disk/by-partlabel/$pointer"
      if [ -e "$candidate" ] && trySlot "$candidate"; then
        chosen="$candidate"
        echo "nixrescue: pointer names '$pointer' -- honoured"
      else
        echo "nixrescue: pointer names '$pointer' but its superblock check failed (or it does not exist) -- falling back to probing"
      fi
    fi

    if [ -z "$chosen" ]; then
      for candidate in /dev/disk/by-partlabel/nixrescue-slot-*; do
        [ -e "$candidate" ] || continue
        if trySlot "$candidate"; then
          chosen="$candidate"
          echo "nixrescue: probing found a usable slot at $candidate"
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

  # The Nix database baked into the squashfs by the same closureInfo-driven `make-squashfs.nix`
  # every consumer of this arrangement should build the slot with (copied pattern, see this file's
  # own header) -- same oneshot-before-nix-daemon ordering `iso-image.nix` itself uses.
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
}
