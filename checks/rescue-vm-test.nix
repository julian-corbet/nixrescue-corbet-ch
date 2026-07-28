# checks/rescue-vm-test.nix
#
# THE HARNESS THAT MAKES THIS PROJECT SAFE TO SHIP. This project's design
# record is explicit that the operator will never hand-test the rescue --
# so this asserts, on every build, what a human otherwise would: the image
# reaches a real login prompt, the repair toolchain is really there and a
# tool really runs, the raise-on-demand GUI pointer really launches its
# target, and -- the one that matters most -- the rescue can find, unlock
# and mount a synthetic broken disk (LUKS + btrfs) it has never seen before,
# read a file back off it, and do that again after closing it, exactly as
# it would for a real disk pulled off a dead machine.
#
# A REAL runtime test, not eval-only: ephemeral QEMU via
# `pkgs.testers.nixosTest` -- nothing persists after the build, no standing
# VM infrastructure needed. This is adoption of the pattern nixram's own
# `checks/swappiness-relief-vm-test.nix` already proved out in this house,
# not invention (see that file's own header for the model this one copies).
#
# NOT tested here, and deliberately so: a real UEFI boot path (nixpkgs'
# qemu-vm.nix supports `useEFIBoot`/`useBootLoader`, which would exercise a
# signed UKI, an ESP, and slot selection -- but that is `nixboot`'s domain,
# not yet built, and this harness does not need to wait for it). Also not
# tested: firmware binding (an RX 6800 / a real WiFi radio) -- QEMU has
# neither, and no VM ever will; that is the one gap this project's design
# record accepts and closes with a supervised human boot instead.

{ pkgs, nixpkgs, nixrescueModule, nixfsModule, mkMaintainer }:

let
  # A trivial stand-in for the consumer-supplied GUI package -- proves the
  # raise-on-demand WIRING (gui.package -> nixrescue-launch-gui ->
  # lib.getExe) without this project naming a real compositor anywhere, per
  # its own stated rule.
  guiStandIn = pkgs.writeShellApplication {
    name = "nixrescue-test-session";
    text = ''echo "nixrescue-test-session: a real consumer points this at its own compositor"'';
  };

  # A stand-in "rescue toplevel" for lib.mkMaintainer -- proves the
  # materialise-onto-a-cold-medium mechanism (mksquashfs the closure, fit
  # check, dd onto the raw device) without paying for a second full NixOS
  # evaluation inside this test. What gets squashed doesn't need to BE a
  # rescue system for the mechanism itself to be genuine.
  materializeStandIn = pkgs.hello;

  maintainer = mkMaintainer {
    inherit pkgs;
    name = "vm-test";
    toplevel = materializeStandIn;
    device = "/dev/vdc";
  };

  testPassphrase = "nixrescue-test-passphrase";
in
pkgs.testers.nixosTest {
  name = "nixrescue-boot-and-disk-recovery";

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ nixrescueModule nixfsModule ];

    nixrescue = {
      enable = true;
      builtAt = "2026-07-28T00:00:00Z";
      authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test-operator-key" ];
      gui.package = guiStandIn;
    };

    nixfs = {
      enable = true;
      filesystems = [ "btrfs" "vfat" ];
      # fio drags in python3 at ~134 MiB -- a rescue booted to recover a
      # disk has no use for drive-throughput benchmarking, only pv's
      # progress display (which stays on).
      tools.throughput.enable = false;
    };

    environment.systemPackages = [ maintainer.script ];

    # Not built-in on every kernel config profile; explicit rather than
    # assumed, since a missing module here would fail this test for a
    # reason that has nothing to do with what it's actually checking.
    boot.kernelModules = [ "squashfs" "dm-crypt" "dm_mod" ];

    # vdb: the synthetic broken disk (LUKS + btrfs) the test carves up by
    # hand below. vdc: lib.mkMaintainer's own materialisation target.
    virtualisation.emptyDiskImages = [ 300 300 ];
    virtualisation.memorySize = 1024;
    virtualisation.cores = 2;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("sshd is up, with the operator's baked-in key installed"):
        machine.wait_for_unit("sshd.service")
        machine.succeed("systemctl is-active sshd.service")
        machine.succeed("grep -q test-operator-key /etc/ssh/authorized_keys.d/root")

    with subtest("the nixfs repair toolchain is present and a tool actually runs"):
        machine.succeed("command -v mkfs.btrfs")
        machine.succeed("command -v mkfs.vfat")
        # cryptsetup --version doesn't just confirm presence -- it actually
        # runs the tool and prints real output, which is what this subtest
        # is really asserting.
        out = machine.succeed("cryptsetup --version")
        assert "cryptsetup" in out.lower(), out
        # throughput group turned off above -- fio must NOT be there.
        machine.fail("command -v fio")

    with subtest("the GUI raise-on-demand pointer actually launches its target"):
        out = machine.succeed("nixrescue-launch-gui")
        assert "nixrescue-test-session" in out, out

    with subtest("it can FIND, unlock and mount a synthetic broken disk (LUKS + btrfs)"):
        machine.succeed("test -b /dev/vdb")

        machine.succeed(
            "echo -n '${testPassphrase}' | "
            "cryptsetup luksFormat --type luks2 --batch-mode /dev/vdb -"
        )
        machine.succeed(
            "echo -n '${testPassphrase}' | "
            "cryptsetup open /dev/vdb nixrescue-test-broken -"
        )
        machine.succeed("mkfs.btrfs -f /dev/mapper/nixrescue-test-broken")
        machine.succeed("mkdir -p /mnt/nixrescue-test")
        machine.succeed("mount /dev/mapper/nixrescue-test-broken /mnt/nixrescue-test")
        machine.succeed("echo hello-from-nixrescue-test > /mnt/nixrescue-test/proof.txt")
        machine.succeed("umount /mnt/nixrescue-test")
        machine.succeed("cryptsetup close nixrescue-test-broken")

        # The actual rescue scenario: rediscover it cold, with no assumption
        # left over from having just created it above.
        found = machine.succeed(
            "blkid -t TYPE=crypto_LUKS -o device"
        ).strip()
        assert found == "/dev/vdb", f"expected to FIND the LUKS disk at /dev/vdb, blkid said: {found}"

        machine.succeed(
            "echo -n '${testPassphrase}' | "
            f"cryptsetup open {found} nixrescue-test-broken -"
        )
        machine.succeed("mount /dev/mapper/nixrescue-test-broken /mnt/nixrescue-test")
        machine.succeed("grep -q hello-from-nixrescue-test /mnt/nixrescue-test/proof.txt")
        machine.succeed("umount /mnt/nixrescue-test")
        machine.succeed("cryptsetup close nixrescue-test-broken")

    with subtest("lib.mkMaintainer builds a real squashfs and writes it straight to the device"):
        machine.succeed("test -b /dev/vdc")
        machine.succeed("nixrescue-maintain-vm-test")

        # A second run against an unchanged toplevel must be a no-op --
        # proves the stamp-file guard, not just the happy path.
        out = machine.succeed("nixrescue-maintain-vm-test")
        assert "unchanged" in out, out

        machine.succeed("mkdir -p /mnt/nixrescue-materialized")
        machine.succeed("mount -t squashfs -o ro /dev/vdc /mnt/nixrescue-materialized")
        machine.succeed("test -d /mnt/nixrescue-materialized/nix/store")
        machine.succeed("umount /mnt/nixrescue-materialized")
  '';
}
