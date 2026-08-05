# modules/nixrescue.nix
#
# The rescue layer's own runtime contract. This module is imported into a
# rescue's OWN `nixosConfigurations.<host>-rescue` -- a real NixOS
# configuration regardless of what the main in front of it is -- and is
# NEVER imported by a main. A main's only contact with this project is
# `lib.mkMaintainer`, a plain function (see ../lib/mkMaintainer.nix), which
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
#           PUBLIC keys baked into the image so it is reachable over SSH
#           before any private identity unlocks (authorizedKeys); which
#           device this rescue attempts to open as its vault and how long it
#           waits for a passphrase before falling back to a local-only boot
#           (vault.*); and a staleness stamp a human can read at the console,
#           because the failure mode that actually kills a rescue is a
#           quietly stale image, not a broken one (builtAt).
#   NOT   : the kernel. Every rescue reuses its host's own stock
#           `boot.kernelPackages` line, whatever the consumer's own
#           `nixosConfigurations.<host>-rescue` already says. There is no
#           `nixrescue.kernel.*` to duplicate that choice -- the kernel is
#           pinned at materialisation time simply by which toplevel
#           `lib.mkMaintainer` was pointed at, not by an option here.
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
#   NOT   : materialisation onto the cold medium, or any timer that runs on
#           the MAIN -- that is `lib.mkMaintainer`, a plain function a main
#           calls directly, never a module a main imports. Keeping the two
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
        image rather than waiting on a vault to unlock is what makes the rescue
        reachable over SSH the moment it is up, using its own ephemeral per-boot
        host key. Empty means console-only until a vault (if one is configured
        at all) opens and brings up whatever private identity that carries.
      '';
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

    builtAt = lib.mkOption {
      type = lib.types.str;
      # Deliberately NO default -- see nixboot's `loader.efiVariables` for the
      # same convention. This is a genuinely per-build fact, not a guess: Nix
      # evaluation is pure and static, so a config that invented its own build
      # time would be lying about the one fact this option exists to keep
      # honest. Left unset, the reference to it below is what turns "forgot to
      # stamp the build" into an eval-time failure instead of a silently blank
      # banner nobody notices until the image is already stale.
      example = "2026-07-28T00:00:00Z";
      description = ''
        An ISO-8601 timestamp, set by whatever materialises this image,
        stamped into the built closure so a human at the console -- or a later
        automated staleness alarm -- can tell how old THIS rescue actually is,
        independent of when the main it sits in front of last rebuilt. There is
        no default and never will be one: the failure mode that actually kills
        a rescue is not a broken image but one that quietly stopped updating,
        and a fabricated timestamp would defeat the one mechanism that makes
        that visible.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # systemd-boot displays a UKI's os-release PRETTY_NAME. This rescue is
    # NixOS-built, but its operator-facing boot identity is nixrescue.
    system.nixos.extraOSReleaseArgs.PRETTY_NAME = "nixrescue";

    services.openssh = {
      enable = lib.mkDefault true;
      settings.PermitRootLogin = lib.mkDefault "prohibit-password";
    };

    users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

    environment.systemPackages =
      lib.optionals (cfg.gui.package != null) [
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
        runtimeInputs = [ pkgs.cryptsetup pkgs.util-linux ];
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

    # Staleness is the failure mode this option exists to make visible, so it
    # is shown on every login rather than waiting to be asked for.
    environment.etc."motd".text = ''

      nixrescue: this image was built at ${cfg.builtAt}
    '';

    assertions = [
      {
        assertion = cfg.vault.device == null || lib.hasPrefix "/dev/" cfg.vault.device;
        message = ''
          nixrescue.vault.device must be an absolute /dev path (a by-id or
          by-partlabel symlink under /dev is fine) -- got: ${toString cfg.vault.device}
        '';
      }
      {
        # Forces `cfg.builtAt` at the same shallow level NixOS already
        # evaluates every other assertion, so a missing value fails here --
        # cleanly, every time -- rather than however many derivation layers
        # deep into `environment.etc."motd"` construction the option system's
        # own "used but not defined" throw would otherwise first get forced.
        assertion = cfg.builtAt != "";
        message = ''
          nixrescue.builtAt has no default and must be set explicitly by
          whatever materialises this image -- see the option's own
          description for why.
        '';
      }
    ];
  };
}
