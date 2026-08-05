# lib/mkMaintainer.nix
#
# The mechanism a MAIN calls -- a PLAIN FUNCTION, not a NixOS module. "Mount
# a device and run a script on a timer" needs nothing NixOS-specific, so a
# NixOS main and a system-manager main call this identically: both accept
# `systemd.services.<name>` / `systemd.timers.<name>` as plain attribute
# sets, and neither needs a module system to merge the result of a plain
# function call into its own config. This is the one and only place this
# project's design record puts on the MAIN's side of the boundary -- see
# ../modules/nixrescue.nix's SCOPE comment for the rest of it.
#
# WHAT IT ACTUALLY DOES, in the shape the design record settled on
# (squashfs, no containing filesystem -- a slot is a valid superblock or it
# is not):
#   1. Skip entirely if the target's already-materialised toplevel (recorded
#      in a stamp file under /var/lib) matches the one requested -- avoiding
#      wear on flash media and a needless device rewrite on every timer
#      firing when nothing actually changed.
#   2. Otherwise: write a Nix-built squashfs of the toplevel's full closure
#      (every requisite, not just the toplevel path itself -- the closure is
#      the thing that has to run) onto the raw device.
#   3. Refuse -- loudly, before writing a single byte -- if the built image
#      would not fit the target device. A truncated rescue is worse than no
#      rescue at all, because it LOOKS like one until the day it's needed.
#
# WHAT IT DELIBERATELY DOES NOT DO: build or sign a UKI, touch the ESP, or
# register a boot entry. That is `nixboot.extraEntries`, once it exists (see
# the design record's own "Open" section) -- this function's whole job ends
# at "the bytes are on the device", the same boundary nixboot's own
# switch-root ownership draws on the other side.
#
{ pkgs
, name # A short, stable identifier for this materialisation target (e.g.
  # "slot-a", "stick-b") -- used for the stamp path and the systemd
  # unit description. Not interpreted otherwise.
, toplevel # The rescue's own built system.build.toplevel, passed as a
  # derivation from the SAME flake evaluation as the main -- exactly the
  # `nixnas.rescue.toplevel` pattern this project's design record points
  # at, e.g.:
  #   self.nixosConfigurations."<host>-rescue".config.system.build.toplevel
, device # The raw block device or partition this materialises onto, e.g.
  # "/dev/disk/by-partlabel/nixrescue-a". No containing filesystem is
  # created or expected -- squashfs is written directly to the device.
, onCalendar ? "daily" # systemd calendar spec for the maintenance timer.
, compressionLevel ? 22 # squashfs -Xcompression-level. 22 is the design
  # measured choice (mksquashfs -comp zstd -Xcompression-level 22
  # -b 1M): roughly 2.9x on a rescue-shaped NixOS closure, in seconds
  # rather than minutes -- erofs at the same level measured both larger
  # AND an order of magnitude slower in wall time, so squashfs is not a
  # default picked for convenience. 1M is squashfs's maximum block size;
  # the trade is that reading one byte decompresses a whole megabyte,
  # which is irrelevant for an image that is read into RAM once.
}:

let
  # NixOS's own live-media image builder produces the flat lower-store layout
  # (`<hash>-<name>` at the squashfs root) and the nix-path-registration
  # manifest that the rescue's overlay boot needs. Building it here keeps
  # compression work on the configured builder, never on the receiving host.
  makeSquashfs = pkgs.callPackage (pkgs.path + "/nixos/lib/make-squashfs.nix");
  image = makeSquashfs {
    fileName = "nixrescue-${name}";
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level ${toString compressionLevel}";
  };

  script = pkgs.writeShellApplication {
    name = "nixrescue-maintain-${name}";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux ];
    text = ''
      set -euo pipefail

      toplevel="${toplevel}"
      image="${image}"
      device="${device}"
      stampdir="/var/lib/nixrescue/${name}"
      stampfile="$stampdir/last-materialized"

      mkdir -p "$stampdir"

      if [ -r "$stampfile" ] && [ "$(cat "$stampfile")" = "$toplevel" ]; then
        echo "nixrescue-maintain (${name}): unchanged ($toplevel) -- nothing to do."
        exit 0
      fi

      [ -b "$device" ] || {
        echo "nixrescue-maintain (${name}): $device is not a block device" >&2
        exit 1
      }

      [ -r "$image" ] || {
        echo "nixrescue-maintain (${name}): pre-built image is absent: $image" >&2
        exit 1
      }

      size=$(stat -c%s "$image")
      devsize=$(blockdev --getsize64 "$device")
      if [ "$size" -gt "$devsize" ]; then
        echo "nixrescue-maintain (${name}): image is $size bytes, $device only holds $devsize -- refusing to write a truncated rescue." >&2
        exit 1
      fi

      dd if="$image" of="$device" bs=4M conv=fsync status=progress
      echo "$toplevel" > "$stampfile"
      echo "nixrescue-maintain (${name}): materialised $toplevel -> $device ($size of $devsize bytes)."
    '';
  };
in
{
  inherit image script;

  # Ready to assign directly: `systemd.services.<anything> = result.service;`
  # on either a NixOS main or a system-manager main -- both understand this
  # shape natively, which is the entire reason this stays a plain attrset
  # rather than a module.
  service = {
    description = "nixrescue: materialise the ${name} rescue image onto its cold medium";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${script}/bin/nixrescue-maintain-${name}";
    };
  };

  timer = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = onCalendar;
      Persistent = true;
    };
  };
}
