# Reconcile one immutable nixrescue release onto either a raw A/B/C set or one explicit in-place
# slot, plus the matching bounded UKI history.
#
# This is intentionally a plain function: NixOS and system-manager hosts both produce ordinary
# systemd units, while nixdeploy invokes the same resulting command after a successful receiver
# pass. The command accepts the signed manifest's artifact path as its only optional argument and
# refuses if it differs from the release compiled into the running system closure.
{ pkgs
, name
, release
, slots
, updateMode ? "atomic-slots"
, espMountPoint ? "/boot"
, espFileName ? "nixrescue.efi"
, pointerFile ? "/EFI/nixrescue/current"
, historyKeep ? 3
, signing ? { enable = false; dbKey = null; dbCert = null; }
}:

let
  inherit (pkgs) lib;
  historyFileName = index:
    if index == 0 then espFileName
    else if index == 1 then "${lib.removeSuffix ".efi" espFileName}-prev.efi"
    else "${lib.removeSuffix ".efi" espFileName}-prev-${toString index}.efi";
  historyFiles = map historyFileName (lib.range 0 (historyKeep - 1));
  signEnabled = signing.enable or false;
  dbKey = signing.dbKey or null;
  dbCert = signing.dbCert or null;
  slotCount = builtins.length slots;
in
assert lib.assertMsg (builtins.elem updateMode [ "atomic-slots" "in-place" ])
  "nixrescue.mkReconciler: updateMode must be either atomic-slots or in-place";
assert lib.assertMsg
  (if updateMode == "atomic-slots" then slotCount >= 3 else slotCount == 1)
  "nixrescue.mkReconciler: atomic-slots requires at least three slots; in-place requires exactly one";
assert historyKeep > 0;
assert lib.assertMsg (lib.hasPrefix "/" pointerFile && !(lib.hasInfix ".." pointerFile))
  "nixrescue.mkReconciler: pointerFile must be an absolute safe path within the ESP";
assert lib.assertMsg
  (if updateMode == "atomic-slots" then historyKeep >= 2 else historyKeep == 1)
  "nixrescue.mkReconciler: atomic-slots requires current plus previous UKIs; in-place permits current only";
assert (!signEnabled) || (dbKey != null && dbCert != null);
pkgs.writeShellApplication {
  name = "nixrescue-reconcile-${name}";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.util-linux
    pkgs.binutils
  ] ++ lib.optionals signEnabled [ pkgs.sbsigntool ];
  text = ''
    set -euo pipefail

    declared_release=${lib.escapeShellArg (toString release)}
    requested_release="''${1:-$declared_release}"
    if [ "$requested_release" != "$declared_release" ]; then
      echo "nixrescue-reconcile-${name}: signed manifest named $requested_release, but this system declares $declared_release" >&2
      exit 1
    fi

    image="$declared_release/image"
    unsigned_uki="$declared_release/uki.efi"
    image_sha256_file="$declared_release/image-sha256"
    image_size_file="$declared_release/image-size"
    slot_devices=(${lib.concatMapStringsSep " " lib.escapeShellArg slots})
    history_files=(${lib.concatMapStringsSep " " lib.escapeShellArg historyFiles})
    expected_init="$(tr -d '\r\n' < "$declared_release/init-path")"
    case "$expected_init" in
      /nix/store/*/init) ;;
      *) echo "nixrescue-reconcile-${name}: invalid release init path: $expected_init" >&2; exit 1 ;;
    esac

    esp=${lib.escapeShellArg espMountPoint}
    esp_dir="$esp/EFI/Linux"
    [ -d "$esp" ] || { echo "nixrescue-reconcile-${name}: ESP mount is absent: $esp" >&2; exit 1; }
    [ "$(findmnt -nro FSTYPE --target "$esp")" = vfat ] || {
      echo "nixrescue-reconcile-${name}: $esp is not a mounted vfat ESP" >&2
      exit 1
    }
    [ -r "$image" ] && [ -r "$unsigned_uki" ] \
      && [ -r "$image_sha256_file" ] && [ -r "$image_size_file" ] || {
      echo "nixrescue-reconcile-${name}: release bundle is incomplete: $declared_release" >&2
      exit 1
    }
    expected_image_sha256="$(tr -d '\r\n' < "$image_sha256_file")"
    expected_image_size="$(tr -d '\r\n' < "$image_size_file")"
    case "$expected_image_sha256" in
      *[!0-9a-f]*|"")
        echo "nixrescue-reconcile-${name}: release has an invalid image SHA-256 digest" >&2
        exit 1
        ;;
    esac
    [ "''${#expected_image_sha256}" -eq 64 ] || {
      echo "nixrescue-reconcile-${name}: release image digest is not 64 hexadecimal characters" >&2
      exit 1
    }
    case "$expected_image_size" in
      *[!0-9]*|""|0)
        echo "nixrescue-reconcile-${name}: release has an invalid image size" >&2
        exit 1
        ;;
    esac
    [ "$(stat -Lc%s "$image")" = "$expected_image_size" ] || {
      echo "nixrescue-reconcile-${name}: image byte length disagrees with release metadata" >&2
      exit 1
    }
    [ "$(sha256sum "$image" | cut -d' ' -f1)" = "$expected_image_sha256" ] || {
      echo "nixrescue-reconcile-${name}: image digest disagrees with release metadata" >&2
      exit 1
    }

    work="$(mktemp -d -t nixrescue-reconcile-${name}-XXXXXX)"
    probe="$work/probe"
    mkdir -p "$probe"
    cleanup() {
      mountpoint -q "$probe" && umount "$probe" || true
      find "$work" -type f -exec shred -u {} \; 2>/dev/null || true
      rm -rf "$work"
    }
    trap cleanup EXIT

    uki_parameter() {
      local file="$1" key="$2" section="$work/cmdline-$RANDOM" rewritten="$work/objcopy-$RANDOM"
      local command_line argument found=""
      [ -r "$file" ] || return 1
      [ "$(head -c2 "$file")" = MZ ] || return 1
      # With no explicit output, objcopy rewrites its input in place even for --dump-section.
      # Never mutate an ESP UKI after signature verification; discard the rewritten copy.
      objcopy --dump-section ".cmdline=$section" "$file" "$rewritten" >/dev/null 2>&1 || return 1
      rm -f "$rewritten"
      command_line="$(tr -d '\000' < "$section")"
      rm -f "$section"
      for argument in $command_line; do
        if [ "''${argument%%=*}" = "$key" ]; then
          found="''${argument#*=}"
        fi
      done
      [ -n "$found" ] || return 1
      printf '%s\n' "$found"
    }

    uki_init() {
      local found
      found="$(uki_parameter "$1" init)" || return 1
      case "$found" in /nix/store/*/init) printf '%s\n' "$found" ;; *) return 1 ;; esac
    }

    uki_image_sha256() {
      local found
      found="$(uki_parameter "$1" nixrescue.imageSha256)" || return 1
      case "$found" in *[!0-9a-f]*|"") return 1 ;; esac
      [ "''${#found}" -eq 64 ] || return 1
      printf '%s\n' "$found"
    }

    uki_image_size() {
      local found
      found="$(uki_parameter "$1" nixrescue.imageSize)" || return 1
      case "$found" in *[!0-9]*|""|0) return 1 ;; esac
      printf '%s\n' "$found"
    }

    signature_valid() {
      ${if signEnabled then ''
      sbverify --cert ${lib.escapeShellArg dbCert} "$1" >/dev/null 2>&1
      '' else ''
      [ "$(head -c2 "$1")" = MZ ]
      ''}
    }

    declare -A slot_hash_cache=()
    slot_hash() {
      local slot="$1" size="$2" key="$1|$2"
      if [ -n "''${slot_hash_cache[$key]+present}" ]; then
        SLOT_HASH_RESULT="''${slot_hash_cache[$key]}"
        return 0
      fi
      [ -b "$slot" ] || return 1
      [ "$size" -le "$(blockdev --getsize64 "$slot")" ] || return 1
      SLOT_HASH_RESULT="$(head -c "$size" "$slot" | sha256sum | cut -d' ' -f1)" || return 1
      slot_hash_cache["$key"]="$SLOT_HASH_RESULT"
    }

    slot_matches_image() {
      local slot="$1" hash="$2" size="$3"
      slot_hash "$slot" "$size" || return 1
      [ "$SLOT_HASH_RESULT" = "$hash" ]
    }

    slot_has_release() {
      local slot="$1" init="$2" relative
      local hash="$3" size="$4"
      slot_matches_image "$slot" "$hash" "$size" || return 1
      [ -b "$slot" ] || return 1
      relative="''${init#/nix/store/}"
      mount -t squashfs -o ro "$slot" "$probe" >/dev/null 2>&1 || return 1
      if [ -e "$probe/$relative" ] && [ -r "$probe/nix-path-registration" ]; then
        umount "$probe"
        return 0
      fi
      umount "$probe"
      return 1
    }

    any_slot_has_release() {
      local init="$1" hash="$2" size="$3" slot
      for slot in "''${slot_devices[@]}"; do
        slot_has_release "$slot" "$init" "$hash" "$size" && return 0
      done
      return 1
    }

    valid_entry() {
      local file="$1" init hash size
      signature_valid "$file" || return 1
      init="$(uki_init "$file")" || return 1
      hash="$(uki_image_sha256 "$file")" || return 1
      size="$(uki_image_size "$file")" || return 1
      any_slot_has_release "$init" "$hash" "$size"
    }

    uki_matches_declared_release() {
      local file="$1"
      signature_valid "$file" \
        && [ "$(uki_init "$file")" = "$expected_init" ] \
        && [ "$(uki_image_sha256 "$file")" = "$expected_image_sha256" ] \
        && [ "$(uki_image_size "$file")" = "$expected_image_size" ]
    }

    find_declared_release_slot() {
      local slot
      matching_slot=""
      for slot in "''${slot_devices[@]}"; do
        if slot_has_release "$slot" "$expected_init" "$expected_image_sha256" "$expected_image_size"; then
          matching_slot="$slot"
          return 0
        fi
      done
      return 1
    }

    publish_pointer() {
      local label pointer_path pointer_dir
      label="$(lsblk -dnro PARTLABEL "$matching_slot" | head -n1 | tr -d '\r\n')"
      case "$label" in
        *[!A-Za-z0-9._-]*|"")
          echo "nixrescue-reconcile-${name}: cannot publish unsafe PARTLABEL for $matching_slot" >&2
          return 1
          ;;
      esac
      pointer_path="$esp${pointerFile}"
      pointer_dir="$(dirname "$pointer_path")"
      mkdir -p "$pointer_dir"
      printf '%s\n' "$label" > "$pointer_path.new"
      sync "$pointer_path.new"
      mv -f "$pointer_path.new" "$pointer_path"
      sync "$pointer_path"
    }

    record_release() {
      mkdir -p "/var/lib/nixrescue/${name}"
      printf '%s\n' "$declared_release" > "/var/lib/nixrescue/${name}/last-release.new"
      mv -f "/var/lib/nixrescue/${name}/last-release.new" "/var/lib/nixrescue/${name}/last-release"
    }

    mkdir -p "$esp_dir"
    current="$esp_dir/${builtins.elemAt historyFiles 0}"
    valid_old=()
    protected_hash=()
    protected_size=()
    index=0
    for filename in "''${history_files[@]}"; do
      file="$esp_dir/$filename"
      if valid_entry "$file"; then
        cp --reflink=auto "$file" "$work/old-$index.efi"
        valid_old+=("$work/old-$index.efi")
        if [ "$index" -lt 2 ]; then
          protected_hash+=("$(uki_image_sha256 "$file")")
          protected_size+=("$(uki_image_size "$file")")
        fi
      elif [ -e "$file" ]; then
        echo "nixrescue-reconcile-${name}: ignoring invalid history entry $file" >&2
      fi
      index=$((index + 1))
    done

    if uki_matches_declared_release "$current" && find_declared_release_slot; then
      publish_pointer
      record_release
      echo "nixrescue-reconcile-${name}: release already coherent: $declared_release"
      exit 0
    fi

    # Finish and verify the UKI before touching any slot. This is essential for one-slot media:
    # after the sole squashfs is overwritten there must be no remaining signing operation that
    # could fail before the matching UKI is ready for its final atomic publication.
    ${if signEnabled then ''
    [ -r ${lib.escapeShellArg dbKey} ] && [ -r ${lib.escapeShellArg dbCert} ] || {
      echo "nixrescue-reconcile-${name}: runtime db signing material is unavailable" >&2
      exit 1
    }
    sbsign --key ${lib.escapeShellArg dbKey} --cert ${lib.escapeShellArg dbCert} \
      --output "$work/new.efi" "$unsigned_uki"
    signature_valid "$work/new.efi" || {
      echo "nixrescue-reconcile-${name}: the newly signed UKI did not verify" >&2
      exit 1
    }
    '' else ''
    cp --reflink=auto "$unsigned_uki" "$work/new.efi"
    ''}
    uki_matches_declared_release "$work/new.efi" || {
      echo "nixrescue-reconcile-${name}: UKI and image release metadata disagree" >&2
      exit 1
    }

    if ! find_declared_release_slot; then
      ${if updateMode == "in-place" then ''
      target_slot=${lib.escapeShellArg (builtins.head slots)}
      [ -b "$target_slot" ] || {
        echo "nixrescue-reconcile-${name}: the declared single slot is not a block device: $target_slot" >&2
        exit 1
      }
      echo "nixrescue-reconcile-${name}: one-slot medium; rewriting $target_slot in place (no on-medium rollback)"
      '' else ''
      target_slot=""
      for slot in "''${slot_devices[@]}"; do
        [ -b "$slot" ] || continue
        safe=yes
        for ((protected_index=0; protected_index<''${#protected_hash[@]}; protected_index++)); do
          if slot_matches_image "$slot" "''${protected_hash[$protected_index]}" "''${protected_size[$protected_index]}"; then
            safe=no
            break
          fi
        done
        if [ "$safe" = yes ]; then target_slot="$slot"; break; fi
      done
      [ -n "$target_slot" ] || {
        echo "nixrescue-reconcile-${name}: every slot backs current or previous; refusing to destroy rollback" >&2
        exit 1
      }
      echo "nixrescue-reconcile-${name}: writing new release to inactive $target_slot"
      ''}
      if findmnt -rn --source "$target_slot" >/dev/null; then
        echo "nixrescue-reconcile-${name}: refusing to rewrite mounted slot $target_slot" >&2
        exit 1
      fi
      device_size="$(blockdev --getsize64 "$target_slot")"
      [ "$expected_image_size" -le "$device_size" ] || {
        echo "nixrescue-reconcile-${name}: image is $expected_image_size bytes, $target_slot holds $device_size" >&2
        exit 1
      }
      dd if="$image" of="$target_slot" bs=4M conv=fsync status=progress
      device_hash="$(head -c "$expected_image_size" "$target_slot" | sha256sum | cut -d' ' -f1)"
      [ "$expected_image_sha256" = "$device_hash" ] || {
        echo "nixrescue-reconcile-${name}: read-back hash mismatch on $target_slot" >&2
        exit 1
      }
      slot_hash_cache=()
      slot_has_release "$target_slot" "$expected_init" "$expected_image_sha256" "$expected_image_size" || {
        echo "nixrescue-reconcile-${name}: written slot does not contain $expected_init" >&2
        exit 1
      }
      matching_slot="$target_slot"
    fi

    sources=("$work/new.efi")
    seen="$expected_init"
    for old in "''${valid_old[@]}"; do
      init="$(uki_init "$old")"
      case " $seen " in *" $init "*) continue ;; esac
      sources+=("$old")
      seen="$seen $init"
    done
    while [ "''${#sources[@]}" -lt ${toString historyKeep} ]; do
      sources+=("$work/new.efi")
    done

    install_one() {
      local source="$1" target="$2" available size
      size="$(stat -c%s "$source")"
      available="$(df -B1 --output=avail "$esp_dir" | tail -n1 | tr -d '[:space:]')"
      [ "$size" -le "$available" ] || {
        echo "nixrescue-reconcile-${name}: ESP lacks $size bytes of atomic staging room ($available free)" >&2
        return 1
      }
      install -m0644 "$source" "$target.new"
      sync "$target.new"
      mv -f "$target.new" "$target"
      sync "$target"
    }

    # Oldest first, current last. A/B/C keeps the current and previous slots untouched throughout.
    # A one-slot update cannot preserve its old squashfs, but it still publishes the already-signed,
    # content-matched current UKI only after the replacement slot has passed read-back verification.
    for ((index=${toString (historyKeep - 1)}; index >= 0; index--)); do
      case "$index" in
        ${lib.concatMapStringsSep "\n        " (index: "${toString index}) filename=${lib.escapeShellArg (builtins.elemAt historyFiles index)} ;;") (lib.range 0 (historyKeep - 1))}
      esac
      install_one "''${sources[$index]}" "$esp_dir/$filename"
    done

    publish_pointer
    record_release
    echo "nixrescue-reconcile-${name}: published coherent release $declared_release"
  '';
}
