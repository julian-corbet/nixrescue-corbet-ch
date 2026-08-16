{ pkgs, lib, mkReconciler }:

let
  mkFakeUki = name: initPath: metadata:
    pkgs.runCommand "${name}.efi" { nativeBuildInputs = [ pkgs.binutils ]; } ''
      printf 'init=${initPath} nixrescue.imageSha256=%s nixrescue.imageSize=%s\0' \
        "$(cat ${metadata}/image-sha256)" "$(cat ${metadata}/image-size)" > cmdline
      objcopy --add-section .cmdline=cmdline \
        ${pkgs.systemd}/lib/systemd/boot/efi/linuxx64.efi.stub "$out"
      test "$(head -c2 "$out")" = MZ
      objcopy --dump-section .cmdline=extracted "$out"
      grep -Fq '${initPath}' extracted
    '';

  mkFakeRelease = name: hash:
    let
      initPath = "/nix/store/${hash}-${name}/init";
      image = pkgs.runCommand "${name}.squashfs" {
        nativeBuildInputs = [ pkgs.squashfsTools ];
      } ''
        mkdir -p "root/${hash}-${name}"
        touch "root/${hash}-${name}/init" root/nix-path-registration
        mksquashfs root "$out" -noappend -comp zstd -quiet
      '';
      metadata = pkgs.runCommand "${name}-image-metadata" { } ''
        mkdir -p "$out"
        sha256sum ${image} | cut -d' ' -f1 > "$out/image-sha256"
        stat -c%s ${image} > "$out/image-size"
      '';
      uki = mkFakeUki name initPath metadata;
    in
    pkgs.runCommand "${name}-release" { } ''
      mkdir -p "$out"
      ln -s ${image} "$out/image"
      ln -s ${uki} "$out/uki.efi"
      ln -s ${metadata}/image-sha256 "$out/image-sha256"
      ln -s ${metadata}/image-size "$out/image-size"
      printf '%s\n' '${initPath}' > "$out/init-path"
      printf '%s\n' '/nix/store/${hash}-${name}' > "$out/toplevel-path"
    '';

  oldRelease = mkFakeRelease "rescue-old" "00000000000000000000000000000000";
  previousRelease = mkFakeRelease "rescue-previous" "11111111111111111111111111111111";
  newRelease = mkFakeRelease "rescue-new" "22222222222222222222222222222222";

  # Test-only key material: it exists solely in this VM derivation to exercise the exact
  # sbsign/sbverify path. Production private keys must never be Nix store inputs.
  testPki = pkgs.runCommand "nixrescue-test-pki" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p "$out"
    openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
      -subj /CN=nixrescue-reconciler-test/ \
      -keyout "$out/db.key" -out "$out/db.pem"
  '';
  signUki = name: uki:
    pkgs.runCommand "${name}-signed.efi" { nativeBuildInputs = [ pkgs.sbsigntool ]; } ''
      sbsign --key ${testPki}/db.key --cert ${testPki}/db.pem \
        --output "$out" ${uki}
      sbverify --cert ${testPki}/db.pem "$out"
    '';
  oldSignedUki = signUki "rescue-old" "${oldRelease}/uki.efi";
  previousSignedUki = signUki "rescue-previous" "${previousRelease}/uki.efi";

  reconciler = mkReconciler {
    inherit pkgs;
    name = "vm-test";
    release = newRelease;
    slots = [
      "/dev/disk/by-partlabel/nixrescue-test-a"
      "/dev/disk/by-partlabel/nixrescue-test-b"
      "/dev/disk/by-partlabel/nixrescue-test-c"
    ];
    espMountPoint = "/mnt/nixrescue-test-esp";
    espFileName = "nixrescue-test.efi";
    historyKeep = 3;
    signing = {
      enable = true;
      dbKey = "${testPki}/db.key";
      dbCert = "${testPki}/db.pem";
    };
  };

  singleReconciler = mkReconciler {
    inherit pkgs;
    name = "single-vm-test";
    release = newRelease;
    slots = [ "/dev/disk/by-partlabel/nixrescue-test-single" ];
    updateMode = "in-place";
    espMountPoint = "/mnt/nixrescue-test-single-esp";
    espFileName = "nixrescue-test-single.efi";
    historyKeep = 1;
    signing = {
      enable = true;
      dbKey = "${testPki}/db.key";
      dbCert = "${testPki}/db.pem";
    };
  };
in
pkgs.testers.nixosTest {
  name = "nixrescue-reconciler-modes";

  nodes.machine = {
    boot.kernelModules = [ "loop" ];
    environment.systemPackages = [
      pkgs.binutils
      pkgs.coreutils
      pkgs.dosfstools
      pkgs.gptfdisk
      pkgs.sbsigntool
      pkgs.util-linux
      reconciler
      singleReconciler
    ];
    virtualisation.memorySize = 768;
    system.stateVersion = lib.trivial.release;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("create a real ESP plus three raw GPT rescue slots"):
        machine.succeed("""
          set -euo pipefail
          truncate -s 320M /tmp/rescue-medium.img
          sgdisk -o /tmp/rescue-medium.img
          sgdisk -n 1:0:+64M -t 1:ef00 -c 1:nixrescue-test-esp /tmp/rescue-medium.img
          sgdisk -n 2:0:+64M -t 2:8300 -c 2:nixrescue-test-a /tmp/rescue-medium.img
          sgdisk -n 3:0:+64M -t 3:8300 -c 3:nixrescue-test-b /tmp/rescue-medium.img
          sgdisk -n 4:0:+64M -t 4:8300 -c 4:nixrescue-test-c /tmp/rescue-medium.img
          losetup --find --show --partscan /tmp/rescue-medium.img > /tmp/rescue-loop
          udevadm settle
          mkfs.vfat -F32 /dev/disk/by-partlabel/nixrescue-test-esp
          mkdir -p /mnt/nixrescue-test-esp
          mount /dev/disk/by-partlabel/nixrescue-test-esp /mnt/nixrescue-test-esp
          mkdir -p /mnt/nixrescue-test-esp/EFI/Linux
          dd if=${oldRelease}/image of=/dev/disk/by-partlabel/nixrescue-test-a bs=4M conv=fsync
          dd if=${previousRelease}/image of=/dev/disk/by-partlabel/nixrescue-test-b bs=4M conv=fsync
          cp ${oldSignedUki} /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test.efi
          cp ${previousSignedUki} /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test-prev.efi
          sync
        """)

    with subtest("the manifest artifact is an exact authority boundary"):
        machine.fail("${lib.getExe reconciler} /nix/store/00000000000000000000000000000000-wrong-release")

    with subtest("write only the safe third slot and rotate verified UKIs"):
        machine.succeed("${lib.getExe reconciler} ${newRelease}")
        machine.succeed("""
          set -euo pipefail
          size=$(stat -Lc%s ${newRelease}/image)
          head -c "$size" /dev/disk/by-partlabel/nixrescue-test-c > /tmp/written-image
          cmp ${newRelease}/image /tmp/written-image
          sbverify --cert ${testPki}/db.pem /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test.efi
          cmp ${oldSignedUki} /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test-prev.efi
          cmp ${previousSignedUki} /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test-prev-2.efi
          objcopy --dump-section .cmdline=/tmp/current-cmdline \
            /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test.efi /tmp/discard-current
          grep -Fq '/nix/store/22222222222222222222222222222222-rescue-new/init' /tmp/current-cmdline
          test "$(cat /mnt/nixrescue-test-esp/EFI/nixrescue/current)" = nixrescue-test-c
        """)

    with subtest("a successful repeat pass is idempotent"):
        before = machine.succeed("sha256sum /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test.efi")
        machine.succeed("${lib.getExe reconciler} ${newRelease}")
        after = machine.succeed("sha256sum /mnt/nixrescue-test-esp/EFI/Linux/nixrescue-test.efi")
        assert before == after

    with subtest("create an independent ESP plus the one permitted raw rescue slot"):
        machine.succeed("""
          set -euo pipefail
          truncate -s 192M /tmp/rescue-single-medium.img
          sgdisk -o /tmp/rescue-single-medium.img
          sgdisk -n 1:0:+64M -t 1:ef00 -c 1:nixrescue-test-single-esp /tmp/rescue-single-medium.img
          sgdisk -n 2:0:+64M -t 2:8300 -c 2:nixrescue-test-single /tmp/rescue-single-medium.img
          losetup --find --show --partscan /tmp/rescue-single-medium.img > /tmp/rescue-single-loop
          udevadm settle
          mkfs.vfat -F32 /dev/disk/by-partlabel/nixrescue-test-single-esp
          mkdir -p /mnt/nixrescue-test-single-esp
          mount /dev/disk/by-partlabel/nixrescue-test-single-esp /mnt/nixrescue-test-single-esp
          mkdir -p /mnt/nixrescue-test-single-esp/EFI/Linux
          dd if=${oldRelease}/image of=/dev/disk/by-partlabel/nixrescue-test-single bs=4M conv=fsync
          cp ${oldSignedUki} /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi
          sync
        """)

    with subtest("single-slot mode rejects the wrong manifest before changing either artifact"):
        before_slot = machine.succeed("sha256sum /dev/disk/by-partlabel/nixrescue-test-single")
        before_uki = machine.succeed("sha256sum /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi")
        machine.fail("${lib.getExe singleReconciler} /nix/store/00000000000000000000000000000000-wrong-release")
        after_slot = machine.succeed("sha256sum /dev/disk/by-partlabel/nixrescue-test-single")
        after_uki = machine.succeed("sha256sum /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi")
        assert before_slot == after_slot
        assert before_uki == after_uki

    with subtest("single-slot mode refuses to rewrite a mounted raw image"):
        machine.succeed("mkdir -p /mnt/nixrescue-test-single-visible && mount -t squashfs -o ro /dev/disk/by-partlabel/nixrescue-test-single /mnt/nixrescue-test-single-visible")
        before_slot = machine.succeed("sha256sum /dev/disk/by-partlabel/nixrescue-test-single")
        before_uki = machine.succeed("sha256sum /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi")
        machine.fail("${lib.getExe singleReconciler} ${newRelease}")
        after_slot = machine.succeed("sha256sum /dev/disk/by-partlabel/nixrescue-test-single")
        after_uki = machine.succeed("sha256sum /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi")
        assert before_slot == after_slot
        assert before_uki == after_uki
        machine.succeed("umount /mnt/nixrescue-test-single-visible")

    with subtest("a plausible but byte-corrupt new image is not mistaken for a completed retry"):
        machine.succeed("""
          set -euo pipefail
          size=$(stat -Lc%s ${newRelease}/image)
          dd if=${newRelease}/image of=/dev/disk/by-partlabel/nixrescue-test-single bs=4M conv=fsync
          printf '\\001' | dd of=/dev/disk/by-partlabel/nixrescue-test-single bs=1 seek="$((size - 1))" conv=notrunc,fsync status=none
          mkdir -p /mnt/nixrescue-test-single-corrupt
          mount -t squashfs -o ro /dev/disk/by-partlabel/nixrescue-test-single /mnt/nixrescue-test-single-corrupt
          test -e /mnt/nixrescue-test-single-corrupt/22222222222222222222222222222222-rescue-new/init
          umount /mnt/nixrescue-test-single-corrupt
        """)

    with subtest("single-slot mode rewrites the sole slot and publishes its matching UKI last"):
        machine.succeed("${lib.getExe singleReconciler} ${newRelease}")
        machine.succeed("""
          set -euo pipefail
          size=$(stat -Lc%s ${newRelease}/image)
          head -c "$size" /dev/disk/by-partlabel/nixrescue-test-single > /tmp/written-single-image
          cmp ${newRelease}/image /tmp/written-single-image
          sbverify --cert ${testPki}/db.pem /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi
          test ! -e /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single-prev.efi
          objcopy --dump-section .cmdline=/tmp/single-current-cmdline \
            /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi /tmp/discard-single-current
          grep -Fq '/nix/store/22222222222222222222222222222222-rescue-new/init' /tmp/single-current-cmdline
          test "$(cat /mnt/nixrescue-test-single-esp/EFI/nixrescue/current)" = nixrescue-test-single
        """)

    with subtest("single-slot repeat reconciliation is idempotent"):
        before = machine.succeed("sha256sum /dev/disk/by-partlabel/nixrescue-test-single /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi")
        machine.succeed("${lib.getExe singleReconciler} ${newRelease}")
        after = machine.succeed("sha256sum /dev/disk/by-partlabel/nixrescue-test-single /mnt/nixrescue-test-single-esp/EFI/Linux/nixrescue-test-single.efi")
        assert before == after
  '';
}
