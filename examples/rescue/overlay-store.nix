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
# more partitions labelled `nixrescue` (one) or `nixrescue-a`/`-b`/`-c` (several), plus an ESP labelled `NIXRESCUE` carrying an optional
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
# SYSTEMD STAGE 1, NOT SCRIPTED. The scripted (classic) initrd is deprecated and scheduled for
# removal in NixOS 26.11 -- the release this repo already tracks (`flake.nix`'s `nixpkgs` input is
# `nixos-unstable`, and at the revision this repo pins, `boot.initrd.systemd.enable` already
# defaults to `true`). This file used to do all of the below in a single
# `boot.initrd.postDeviceCommands` shell script, with the three mounts as ordinary `fileSystems.*`
# entries -- classic stage 1's implicit "run the script, then mount everything neededForBoot in
# mountpoint order" sequence. Neither half of that survives the migration as-is:
#
#   - `postDeviceCommands` has NO systemd-stage-1 equivalent at all. NixOS's own assertion for it
#     says so directly: "systemd stage 1 does not support `boot.initrd.postDeviceCommands`.
#     Instead, create systemd services using the `boot.initrd.systemd.services` options[...]".
#     The slot-resolution logic below is now `nixrescue-resolve-slot`, an ordered oneshot unit --
#     see its own comment for the precedent this shape is copied from.
#   - The three mounts below are declared directly as `boot.initrd.systemd.mounts`, not as
#     `fileSystems.*` (which NixOS would still auto-generate systemd mount units for, via its
#     `x-initrd.mount` fstab tagging -- see `nixos/modules/tasks/filesystems.nix`). Declaring them
#     as raw mount units instead means the ordering between them -- rw-store and ro-store both
#     ready before the overlay merges them -- is a real `after`/`requires` edge in the unit graph
#     that this file states explicitly, rather than something that happened to fall out of
#     whatever order a classic stage-1 script mounted `fileSystems` entries in.
#
# NOT covered by a dedicated test in this repo: this generalised (by-label/by-partlabel) form is a
# straightforward reshaping of the exact mechanism `rescue-uefi-boot-vm-test.nix` already exercises
# against a hand-built two-slot disk -- growing that harness to also drive THIS file's own
# by-partlabel probing loop, rather than the hand-rolled `/dev/vda2`/`/dev/vda3` device names it
# uses today, is the natural next increment (see this project's own testing philosophy, docs/design.md,
# on why the harness is built to grow rather than arrive complete).
#
{ config, lib, pkgs, utils, ... }:

let
  roStoreMount = "/sysroot/nix/.ro-store";
  rwStoreMount = "/sysroot/nix/.rw-store";
  nixStoreMount = "/sysroot/nix/store";

  # The exact same function NixOS's own generated units use to turn a `where` path into a unit
  # name (`nixos/modules/system/boot/systemd/initrd.nix`: `n = escapeSystemdPath v.where;`) --
  # computed here, not hand-typed, so a reference to "the unit backing that mount" can never drift
  # out of sync with what NixOS itself actually names it.
  roStoreUnit = "${utils.escapeSystemdPath roStoreMount}.mount";
  rwStoreUnit = "${utils.escapeSystemdPath rwStoreMount}.mount";
  nixStoreUnit = "${utils.escapeSystemdPath nixStoreMount}.mount";
in
{
  fileSystems."/" = {
    fsType = "tmpfs";
    device = "none";
    options = [ "mode=0755" ];
  };

  # This option's own upstream default, at the revision this repo pins -- stated explicitly
  # because every service and mount below depends on it, not to restate a default for its own
  # sake.
  boot.initrd.systemd.enable = true;

  boot.initrd.availableKernelModules = [
    "squashfs"
    "vfat"
    "nls_cp437"
    "nls_iso8859_1"
  ];
  # "overlay" force-loaded (no "loop" -- a slot is a raw partition, never a file, see this file's
  # own header).
  boot.initrd.kernelModules = [ "overlay" ];

  # ── slot resolution: postDeviceCommands' systemd-stage-1 replacement ────────────────────────
  #
  # Same two-sided ordering idiom nixpkgs' own ZFS initrd pool-import service uses for the
  # identical problem -- "populate a stable device node/symlink a mount unit further down depends
  # on, before that mount unit ever runs" (`nixos/modules/tasks/filesystems/zfs.nix`,
  # `createImportService`: `requiredBy`/`before` both name the mount units it backs;
  # `unitConfig.DefaultDependencies = false` plus an explicit `shutdown.target` conflict, since
  # this has to run as part of the initrd's own early graph, not through the ordinary
  # shutdown-aware chain a stage-2 service gets by default). `requiredBy` alone is not enough -- it
  # adds `Requires=` onto `roStoreUnit`, but `Requires=` does not itself imply ordering, so
  # `before` carries that half.
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
    # coreutils (mkdir/cat/tr/ln/echo) and mount/umount are already on the systemd-stage-1 PATH by
    # default (`initrd.nix`'s own `initrdBin`/`extraBin`) -- nothing extra needed on `path` here.
    # `blkid` is deliberately NOT used to find the ESP: `/dev/disk/by-label/NIXRESCUE` is the same
    # udev-populated symlink a `blkid` query would have had to resolve anyway -- exactly how the
    # slot partitions below are already found, via by-partlabel, with no extra binary either. One
    # fewer tool in an image sized to a fixed slot budget, for behaviour that is otherwise
    # identical to the classic-stage-1 script this replaces.
    script = ''
      echo "nixrescue: resolving which cold-mode slot to boot from"
      mkdir -p /mnt-esp /mnt-slot-probe

      pointer=""
      if [ -e /dev/disk/by-label/NIXRESCUE ] && mount -t vfat -o ro /dev/disk/by-label/NIXRESCUE /mnt-esp 2>/dev/null; then
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
        # `nixrescue*` matches BOTH shapes of the fleet naming rule: a medium with
        # ONE slot names it `nixrescue`, a medium with several names them
        # `nixrescue-a`/`-b`/`-c` (knowledge/fleet/shared/partition-naming.md).
        # The older `nixrescue-slot-*` glob matched neither the bare singular nor
        # anything actually deployed -- a stick carved as `nixrescue-a` would boot
        # this image and find no store at all, silently, because a glob that
        # matches nothing expands to itself and every `[ -e ]` then fails.
        for candidate in /dev/disk/by-partlabel/nixrescue*; do
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
  };

  # ── the overlay mounts themselves: explicit units, explicit ordering ────────────────────────
  #
  # Raw `boot.initrd.systemd.mounts` entries, not `fileSystems.*` sugar -- see this file's own
  # header for why. `where` therefore carries the literal `/sysroot` prefix: unlike `fileSystems.*`
  # (which NixOS's fstab-generator prefixes for you inside the initrd, via its `x-initrd.mount`
  # handling in `nixos/modules/tasks/filesystems.nix`), a raw mount-unit `where` is used exactly as
  # given, with no implicit rewriting.
  boot.initrd.systemd.mounts = [
    {
      # Populated by nixrescue-resolve-slot above, before this unit ever runs -- the same
      # stable-symlink-populated-by-initrd pattern LUKS/LVM device-mapper nodes already rely on.
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
      # NOT automatic: `where` here (/sysroot/nix/store) is not a subpath of either
      # /sysroot/nix/.ro-store or /sysroot/nix/.rw-store, so systemd's own implicit
      # mount-nesting dependency (which fires when one mountpoint IS a subpath of another) never
      # applies here -- both have to be named explicitly. That explicit edge is the entire point
      # of moving this out of an implicit script sequence.
      after = [ roStoreUnit rwStoreUnit ];
      requires = [ roStoreUnit rwStoreUnit ];
      # The one unit in this file actually pulled into the boot transaction by name; ro-store and
      # rw-store above are pulled in transitively through THIS unit's own `requires` (immediately
      # above), not because either names `initrd-fs.target` itself.
      requiredBy = [ "initrd-fs.target" ];
      before = [ "initrd-fs.target" ];
    }
  ];

  # overlayfs needs its upperdir/workdir to exist before the overlay mount is attempted --
  # `/nix/.rw-store` is a fresh tmpfs, so nothing creates them on its own. Same shape as NixOS's
  # own `preMountService` (`nixos/modules/tasks/filesystems/overlayfs.nix`): a oneshot ordered
  # before the mount it prepares for, gated (via `RequiresMountsFor`) on the directory it must
  # create already being mounted.
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

  # The Nix database baked into the squashfs by the same closureInfo-driven `make-squashfs.nix`
  # every consumer of this arrangement should build the slot with (copied pattern, see this file's
  # own header) -- same oneshot-before-nix-daemon ordering `iso-image.nix` itself uses. This is a
  # STAGE 2 service (plain `systemd.services`, not `boot.initrd.systemd.services`) -- it runs after
  # switch_root, entirely unaffected by which stage-1 flavour assembled the store it registers, so
  # nothing here changed with the migration above.
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
