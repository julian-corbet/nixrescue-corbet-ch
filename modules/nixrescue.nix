# modules/nixrescue.nix
#
# The rescue layer's own runtime contract. This module is imported into a
# rescue's OWN `nixosConfigurations.<host>-rescue` -- a real NixOS
# configuration regardless of what the main in front of it is -- and is
# NEVER imported by a main. A main's only contact with this project is through
# `lib.mkRelease`/`lib.mkReconciler`, plain functions, which
# is why this file has no system-manager twin: unlike nixfs/nixram, nothing
# here ever needs to render on a non-NixOS host, because the rescue itself
# is always real NixOS by design.
#
# THE RESCUE IS A NIXOS CONFIGURATION. Its payload -- repair tooling, which
# services run, what a human sees at the console -- is ordinary
# `environment.systemPackages` and ordinary service config in the CONSUMER's
# own `nixosConfigurations.<host>-rescue`. This module exists only for the
# handful of things that are genuinely specific to being a rescue, not a
# restatement of options NixOS already has.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : the second-system contract's runtime surface as it exists ON the
#           rescue OS itself -- which package, if any, raises a graphical
#           session at the console on demand (gui.package); the operator
#           PUBLIC keys baked into the image (authorizedKeys), and whether
#           sshd consumes a per-device TPM-sealed host identity supplied by
#           systemd-stub (ssh.*); which
#           device this rescue attempts to open as its vault and how long it
#           waits for a passphrase before falling back to a local-only boot
#           (vault.*); and a local command that reads the authenticated release
#           identity from the UKI-supplied kernel command line.
#   NOT   : the kernel. Every rescue reuses its host's own stock
#           `boot.kernelPackages` line, whatever the consumer's own
#           `nixosConfigurations.<host>-rescue` already says. There is no
#           `nixrescue.kernel.*` to duplicate that choice -- the kernel is
#           pinned at release-build time simply by which toplevel
#           `lib.mkRelease` was pointed at, not by an option here.
#   NOT   : the ESP entry's filename, signing, or NVRAM registration --
#           nixboot's domain (`nixboot.extraEntries`, once it exists).
#           nixrescue declares repair tooling and a boot target; it never
#           touches firmware handoff.
#   NOT   : anything shaped like `apps.*` or `desktop.enable`. A consumer
#           wanting a text editor, a network tool, a specific shell in its
#           rescue reaches for ordinary `environment.systemPackages` in its
#           OWN configuration -- inventing a second, rescue-flavoured name
#           for the same NixOS option would be exactly the kind of
#           option-that-restates-the-name this project's whole house style
#           forbids.
#   NOT   : scheduling or transport. `lib.mkReconciler` is a plain function a main
#           calls directly (or nixdeploy invokes with an exact signed artifact), never a module
#           a main imports. Keeping the two
#           apart is what lets a NixOS main and a system-manager main call
#           the identical function.
#   NOT   : what goes into the vault, or how it is packed -- nixvault's job.
#           This module only knows WHICH device to try and HOW LONG to wait;
#           it has no opinion on the container's contents, and no dependency
#           on nixvault existing.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.nixrescue;
in
{
  options.nixrescue = {
    enable = lib.mkEnableOption "the rescue layer's runtime contract on this host's own rescue NixOS configuration";

    gui.package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.cage";
      description = ''
        The one package whose single entrypoint raises a graphical session at the
        console, on demand -- never at boot, and never automatically. `null`, the
        default, means headless-only: the rescue still reaches
        `multi-user.target` with sshd up, there is simply nothing to launch at
        the console.

        This project never names a compositor. That choice is entirely the
        consumer's own open question; this option is a bare pointer, resolved
        with `lib.getExe`, so the package must expose a runnable program (either
        a `meta.mainProgram` or a `pname`/`name` nixpkgs can find in `$out/bin`).
      '';
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA... operator" ];
      description = ''
        Operator PUBLIC keys, baked into the image at build time. These are not
        secret -- unlike everything a vault carries -- so shipping them in the
        image rather than waiting on a vault to unlock is safe because they are
        not identity secrets. Empty means console-only. The server identity is
        deliberately not in this list or image; see ssh.tpm2Credential.
      '';
    };

    ssh = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable rescue sshd. Off by default: the universal image always retains a local console,
          while a device class that permits remote rescue opts in explicitly and supplies
          authorizedKeys. With tpm2Credential left at its secure default, sshd starts only when
          systemd-stub delivered the device's TPM-sealed host key from the ESP.
        '';
      };

      tpm2Credential = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Require the per-device nixboot-initrd-hostkey encrypted credential as sshd's only host
          key. A missing credential or TPM/PCR mismatch leaves sshd down and the console usable;
          no ephemeral or plaintext fallback is generated. Disable only in an isolated test.
        '';
      };

      credentialName = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+";
        default = "nixboot-initrd-hostkey";
        description = ''
          Name shared with the systemd-stub global credential on the ESP and the host's nixboot
          seal service. This is a stable protocol name, not a host-specific value.
        '';
      };
    };

    vault = {
      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/disk/by-partlabel/vault";
        description = ''
          Which block device this rescue should attempt to open as its vault
          (a LUKS-to-squashfs container packed by nixvault) once it is up.
          `null`, the default, means this rescue has no vault composed at all:
          a permanently LAN-only rescue with no cross-host identity to unlock -- a
          legitimate, safe choice, not a degraded one.

          This option only knows WHICH device and HOW LONG to wait
          (`unlockTimeoutSec` below); it never decides what goes inside the
          container or how it is packed -- that is nixvault's whole job, kept
          deliberately separate (see this module's SCOPE comment).
        '';
      };

      unlockTimeoutSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = ''
          How long, in seconds, the boot flow waits at the vault passphrase
          prompt (`systemd-ask-password`, answerable at the console or over SSH
          -- the same mechanism nixboot's own initrd remote-unlock already
          uses) before giving up and continuing as a local-only rescue. A
          degraded-but-reachable rescue beats one that blocks forever on a
          human who never shows up.

          Only meaningful when `vault.device` is set; ignored otherwise.
        '';
      };
    };

  };

  config = lib.mkIf cfg.enable {
    # systemd-boot displays a UKI's os-release PRETTY_NAME. This rescue is
    # NixOS-built, but its operator-facing boot identity is nixrescue.
    system.nixos.extraOSReleaseArgs.PRETTY_NAME = "nixrescue";

    services.openssh = {
      enable = cfg.ssh.enable;
      settings.PermitRootLogin = lib.mkDefault "prohibit-password";
      hostKeys = lib.mkIf cfg.ssh.tpm2Credential [ ];
      extraConfig = lib.optionalString cfg.ssh.tpm2Credential ''
        HostKey /run/credentials/sshd.service/${cfg.ssh.credentialName}
      '';
    };

    systemd.services.sshd.serviceConfig = lib.mkIf (cfg.ssh.enable && cfg.ssh.tpm2Credential) {
      LoadCredentialEncrypted = [ cfg.ssh.credentialName ];
      # nixpkgs defaults sshd to Restart=always. That would turn a missing/unsealable TPM
      # credential into a permanent restart loop; strict gating means one hard failure instead.
      Restart = lib.mkForce "no";
    };

    users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

    environment.systemPackages =
      [
        (pkgs.writeShellApplication {
          name = "nixrescue-release-info";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            image_sha256=""
            image_size=""
            init_path=""

            read -r -a cmdline_fields < /proc/cmdline
            for field in "''${cmdline_fields[@]}"; do
              case "$field" in
                nixrescue.imageSha256=*) image_sha256="''${field#*=}" ;;
                nixrescue.imageSize=*) image_size="''${field#*=}" ;;
                init=*) init_path="''${field#*=}" ;;
              esac
            done

            case "$image_sha256" in
              *[!0-9a-f]*|"")
                echo "nixrescue-release-info: UKI supplied no valid image SHA-256" >&2
                exit 1
                ;;
            esac
            if [ "''${#image_sha256}" -ne 64 ]; then
              echo "nixrescue-release-info: UKI supplied a non-SHA-256 image digest" >&2
              exit 1
            fi
            case "$image_size" in
              *[!0-9]*|""|0)
                echo "nixrescue-release-info: UKI supplied no valid image size" >&2
                exit 1
                ;;
            esac
            case "$init_path" in
              /nix/store/*/init) ;;
              *)
                echo "nixrescue-release-info: UKI supplied no valid rescue init path" >&2
                exit 1
                ;;
            esac

            printf 'image-sha256=%s\nimage-size=%s\ninit=%s\n' \
              "$image_sha256" "$image_size" "$init_path"
          '';
        })
      ]
      ++ lib.optionals (cfg.gui.package != null) [
        cfg.gui.package
        (pkgs.writeShellApplication {
          name = "nixrescue-launch-gui";
          text = ''
            exec ${lib.getExe cfg.gui.package} "$@"
          '';
        })
      ]
      ++ lib.optional (cfg.vault.device != null) (pkgs.writeShellApplication {
        name = "nixrescue-unlock-vault";
        # systemd for systemd-ask-password and coreutils for mkdir: neither is in cryptsetup or
        # util-linux, and this script runs in a rescue environment where a bare 127 on the
        # passphrase prompt is the worst possible time to discover a missing runtime input.
        runtimeInputs = [ pkgs.cryptsetup pkgs.util-linux pkgs.systemd pkgs.coreutils ];
        text = ''
          device="${cfg.vault.device}"
          mapping="nixrescue-vault"
          mountpoint="/run/nixrescue/vault"

          if [ -e "/dev/mapper/$mapping" ]; then
            echo "nixrescue-unlock-vault: $mapping is already open" >&2
          else
            systemd-ask-password --timeout=${toString cfg.vault.unlockTimeoutSec} \
                "Vault passphrase for $device: " \
              | cryptsetup open "$device" "$mapping"
          fi

          mkdir -p "$mountpoint"
          mountpoint -q "$mountpoint" || mount -o ro "/dev/mapper/$mapping" "$mountpoint"
          echo "nixrescue-unlock-vault: vault mounted read-only at $mountpoint"
        '';
      });

    environment.etc."motd".text = ''

      nixrescue: run nixrescue-release-info for the authenticated release identity
    '';

    assertions = [
      {
        assertion = !cfg.ssh.enable || cfg.authorizedKeys != [ ];
        message = "nixrescue.ssh.enable requires at least one operator public key in nixrescue.authorizedKeys.";
      }
      {
        assertion = cfg.vault.device == null || lib.hasPrefix "/dev/" cfg.vault.device;
        message = ''
          nixrescue.vault.device must be an absolute /dev path (a by-id or
          by-partlabel symlink under /dev is fine) -- got: ${toString cfg.vault.device}
        '';
      }
    ];
  };
}
