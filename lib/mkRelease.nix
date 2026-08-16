# Build the immutable object a delivery manifest names for the nixrescue boot role.
#
# The raw squashfs and UKI are one release even though they are written to different media. The
# caller builds the UKI through `mkUki` only after this function has hashed the image, so the UKI's
# signed command line cryptographically binds the external bytes it is allowed to mount.
{ pkgs
, toplevel
, mkUki
, name ? "nixrescue"
, compressionLevel ? 22
}:

let
  image = pkgs.callPackage (pkgs.path + "/nixos/lib/make-squashfs.nix") {
    fileName = "${name}.squashfs";
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level ${toString compressionLevel}";
  };

  initPath = "${toplevel}/init";
  imageMetadata = pkgs.runCommand "${name}-image-metadata" { } ''
    set -euo pipefail
    mkdir -p "$out"
    image_hash=$(sha256sum ${image} | cut -d' ' -f1)
    image_size=$(stat -c%s ${image})
    printf '%s\n' "$image_hash" > "$out/image-sha256"
    printf '%s\n' "$image_size" > "$out/image-size"
    printf 'nixrescue.imageSha256=%s nixrescue.imageSize=%s\n' \
      "$image_hash" "$image_size" > "$out/kernel-params"
  '';
  uki = mkUki {
    inherit image imageMetadata initPath toplevel;
    kernelParamFile = "${imageMetadata}/kernel-params";
  };
  bundle = pkgs.runCommand "${name}-release" { nativeBuildInputs = [ pkgs.binutils ]; } ''
    set -euo pipefail
    test "$(head -c2 ${uki})" = MZ
    objcopy --dump-section .cmdline=cmdline ${uki} discarded-uki
    cmdline_text="$(tr -d '\000' < cmdline)"
    image_hash="$(cat ${imageMetadata}/image-sha256)"
    image_size="$(cat ${imageMetadata}/image-size)"
    case " $cmdline_text " in
      *" nixrescue.imageSha256=$image_hash "*) ;;
      *) echo "mkRelease: UKI does not authenticate the rescue image digest" >&2; exit 1 ;;
    esac
    case " $cmdline_text " in
      *" nixrescue.imageSize=$image_size "*) ;;
      *) echo "mkRelease: UKI does not authenticate the rescue image byte length" >&2; exit 1 ;;
    esac

    mkdir -p "$out"
    ln -s ${image} "$out/image"
    ln -s ${uki} "$out/uki.efi"
    ln -s ${imageMetadata}/image-sha256 "$out/image-sha256"
    ln -s ${imageMetadata}/image-size "$out/image-size"
    printf '%s\n' ${pkgs.lib.escapeShellArg initPath} > "$out/init-path"
    printf '%s\n' ${pkgs.lib.escapeShellArg (toString toplevel)} > "$out/toplevel-path"
  '';
in
{
  inherit bundle image imageMetadata initPath toplevel uki;
}
