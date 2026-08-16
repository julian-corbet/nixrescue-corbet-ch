# modules/overlay-store.nix
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
# more declared raw rescue partitions, plus an ESP carrying an optional
# `/EFI/nixrescue/current` preference file. The preference is never an authority: a UKI embeds
# `init=/nix/store/<exact-toplevel>/init` plus the squashfs byte length and SHA-256 digest. This
# resolver hashes the raw bytes before mounting them and accepts only an exact match. The pathname
# remains a coherence check after authentication; it is not mistaken for a cryptographic proof.
#
# WHAT THIS DOES NOT DECIDE: how many slots exist on any given medium, which bootloader placed a UKI
# in front of this, or how bytes got onto the medium in the first place. Those are a boot-arbitration
# module's domain and `lib.mkReconciler`'s, respectively -- see `../../modules/nixrescue.nix`'s own
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
# The UEFI VM check imports this module directly. It proves both preference and fallback using
# GPT PARTLABELs, and proves that a structurally-valid squashfs containing the wrong toplevel is
# rejected rather than selected.
#
{ config, lib, pkgs, utils, ... }:

let
  cfg = config.nixrescue.store;
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
  options.nixrescue.store = {
    slotDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/dev/disk/by-partlabel/nixrescue"
        "/dev/disk/by-partlabel/nixrescue-a"
        "/dev/disk/by-partlabel/nixrescue-b"
        "/dev/disk/by-partlabel/nixrescue-c"
      ];
      description = ''
        Ordered raw squashfs devices this rescue UKI may use as its lower Nix store. Missing
        devices are skipped. A device is usable only when its raw bytes match the size and SHA-256
        digest authenticated by this UKI and it contains the exact embedded init= store path plus
        a nix-path-registration database.
      '';
    };

    espDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/dev/disk/by-partlabel/ESP";
      description = ''
        Optional ESP device carrying EFI/nixrescue/current. The file is only a preference among
        content-compatible slots; it can never select a slot for a different UKI generation.
        null disables the preference file completely.
      '';
    };

    pointerFile = lib.mkOption {
      type = lib.types.str;
      default = "/EFI/nixrescue/current";
      description = "Absolute path, within espDevice, of the optional preferred PARTLABEL.";
    };

    deviceWaitSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        Maximum initrd time to wait for at least one declared slot device before probing. This
        covers kernel/udev discovery without turning a genuinely absent rescue medium into an
        unbounded boot hang.
      '';
    };
  };

  config = {

  fileSystems."/" = {
    fsType = "tmpfs";
    device = "none";
    options = [ "mode=0755" ];
  };

  # Stage 2 otherwise bind-remounts /nix/store read-only even when stage 1 handed it a writable
  # overlay. Rescue needs the tmpfs upper layer for repairs and temporary substitutions.
  boot.nixStoreMountOpts = [ ];

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
  # These are used by the resolver itself, so "available" is insufficient: load them before its
  # mount probes. No "loop" -- a slot is a raw partition, never a file (see this file's header).
  boot.initrd.kernelModules = [ "overlay" "squashfs" "vfat" ];

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
    after = [ "systemd-modules-load.service" ];
    before = [ roStoreUnit "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # `sleep` is load-bearing for the bounded kernel-device discovery wait and is not guaranteed
    # by the minimal initrd PATH, so make the coreutils dependency explicit.
    path = [ pkgs.coreutils pkgs.util-linux ];
    # `blkid` is deliberately NOT used to find the ESP: `/dev/disk/by-label/NIXRESCUE` is the same
    # udev-populated symlink a `blkid` query would have had to resolve anyway -- exactly how the
    # slot partitions below are already found, via by-partlabel, with no extra binary either. One
    # fewer tool in an image sized to a fixed slot budget, for behaviour that is otherwise
    # identical to the classic-stage-1 script this replaces.
    script = ''
      echo "nixrescue: resolving which cold-mode slot to boot from"
      mkdir -p /mnt-esp /mnt-slot-probe

      # This unit is intentionally not Requires=-bound to every possible slot: missing slots are
      # legal, and one generic image lists singular plus A/B/C shapes. Kernel discovery can still
      # finish after the initrd service graph starts, so wait boundedly for ANY candidate instead
      # of making one instantaneous, permanently wrong absence decision.
      remaining=${toString cfg.deviceWaitSeconds}
      while [ "$remaining" -gt 0 ]; do
        slot_seen=""
        for candidate in ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.slotDevices}; do
          if [ -e "$candidate" ]; then
            slot_seen=1
            break
          fi
        done
        [ -n "$slot_seen" ] && break
        sleep 1
        remaining=$((remaining - 1))
      done

      init_path=""
      image_sha256=""
      image_size=""
      for argument in $(cat /proc/cmdline); do
        case "$argument" in
          init=*) init_path="''${argument#init=}" ;;
          nixrescue.imageSha256=*) image_sha256="''${argument#nixrescue.imageSha256=}" ;;
          nixrescue.imageSize=*) image_size="''${argument#nixrescue.imageSize=}" ;;
        esac
      done
      case "$init_path" in
        /nix/store/*/init) ;;
        *)
          echo "nixrescue: FATAL: UKI command line has no safe /nix/store/.../init path" >&2
          exit 1
          ;;
      esac
      case "$init_path" in
        *".."*)
          echo "nixrescue: FATAL: refusing unsafe init path: $init_path" >&2
          exit 1
          ;;
      esac
      relative_init="''${init_path#/nix/store/}"
      case "$image_sha256" in
        *[!0-9a-f]*|"")
          echo "nixrescue: FATAL: UKI command line has no safe lowercase SHA-256 image digest" >&2
          exit 1
          ;;
      esac
      [ "''${#image_sha256}" -eq 64 ] || {
        echo "nixrescue: FATAL: UKI image digest is not 64 hexadecimal characters" >&2
        exit 1
      }
      case "$image_size" in
        *[!0-9]*|""|0)
          echo "nixrescue: FATAL: UKI command line has no safe positive image size" >&2
          exit 1
          ;;
      esac

      pointer=""
      ${lib.optionalString (cfg.espDevice != null) ''
      if [ -e ${lib.escapeShellArg cfg.espDevice} ] && mount -t vfat -o ro ${lib.escapeShellArg cfg.espDevice} /mnt-esp 2>/dev/null; then
        if [ -r /mnt-esp${lib.escapeShellArg cfg.pointerFile} ]; then
          pointer=$(cat /mnt-esp${lib.escapeShellArg cfg.pointerFile} 2>/dev/null | tr -d ' \t\r\n') || true
        fi
        umount /mnt-esp 2>/dev/null || true
      else
        echo "nixrescue: no declared ESP found (or it would not mount) -- probing slots in order" >&2
      fi
      ''}

      # Never ask the kernel's squashfs parser to touch unauthenticated rescue bytes. An attacker
      # can manufacture the signed UKI's expected store pathname inside an arbitrary filesystem;
      # only the digest embedded in that signed UKI authenticates the external image.
      trySlot() {
        [ -b "$1" ] || return 1
        device_size=$(blockdev --getsize64 "$1") || return 1
        [ "$image_size" -le "$device_size" ] || return 1
        actual_sha256=$(head -c "$image_size" "$1" | sha256sum | cut -d' ' -f1) || return 1
        if [ "$actual_sha256" != "$image_sha256" ]; then
          echo "nixrescue: rejecting $1: raw image digest does not match the signed UKI" >&2
          return 1
        fi
        mount -t squashfs -o ro "$1" /mnt-slot-probe || return 1
        if [ ! -e "/mnt-slot-probe/$relative_init" ] || [ ! -r /mnt-slot-probe/nix-path-registration ]; then
          umount /mnt-slot-probe 2>/dev/null || true
          return 1
        fi
        umount /mnt-slot-probe 2>/dev/null || true
        return 0
      }

      chosen=""
      if [ -n "$pointer" ]; then
        case "$pointer" in
          *[!A-Za-z0-9._-]*|"")
            echo "nixrescue: ignoring invalid preferred PARTLABEL '$pointer'" >&2
            ;;
          *)
            candidate="/dev/disk/by-partlabel/$pointer"
            if [ -e "$candidate" ] && trySlot "$candidate"; then
              chosen="$candidate"
              echo "nixrescue: preference names compatible slot '$pointer' -- honoured"
            else
              echo "nixrescue: preference '$pointer' is absent or incompatible with $init_path -- probing" >&2
            fi
            ;;
        esac
      fi

      if [ -z "$chosen" ]; then
        for candidate in ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.slotDevices}; do
          [ -e "$candidate" ] || continue
          if trySlot "$candidate"; then
            chosen="$candidate"
            echo "nixrescue: probing found a slot compatible with $init_path at $candidate"
            break
          fi
        done
      fi

      if [ -z "$chosen" ]; then
        echo "nixrescue: FATAL: no slot matches the UKI's signed image digest and init path $init_path" >&2
        exit 1
      else
        # Keep the selector outside /dev. systemd treats any mount What= below /dev as a device
        # unit and waits for a udev event; a resolver-created symlink has no such event and would
        # deadlock for the default device timeout even though its target already exists.
        ln -sf "$chosen" /run/nixrescue-active-slot
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
      what = "/run/nixrescue-active-slot";
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

  assertions = [
    {
      assertion = cfg.slotDevices != [ ];
      message = "nixrescue.store.slotDevices must name at least one raw rescue slot.";
    }
    {
      assertion = lib.hasPrefix "/" cfg.pointerFile && !(lib.hasInfix ".." cfg.pointerFile);
      message = "nixrescue.store.pointerFile must be an absolute path without '..'.";
    }
  ];
  };
}
