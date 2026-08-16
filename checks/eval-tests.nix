# checks/eval-tests.nix
#
# EVAL-TIME tests for modules/nixrescue.nix. No VM and no build beyond the
# cheap derivations the module produces: every test
# evaluates a full NixOS configuration (nixrescue needs the real option tree
# -- services.openssh, users.*, environment.* -- not a bare `evalModules`
# over its own options alone) and inspects what it RENDERS. See
# rescue-vm-test.nix for the one test that boots anything.

{ pkgs, nixpkgs, nixrescueModule }:

let
  lib = pkgs.lib;

  evalFor = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        nixrescueModule
        extraConfig
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  # Forces NixOS's own real assertion enforcement (system.build.toplevel is
  # where `lib.asserts.checkAssertWarn` actually throws) without deep-forcing
  # the whole system closure -- same technique nixram's own eval-tests use.
  evalFailsBuild = extraConfig:
    !(builtins.tryEval (builtins.seq (evalFor extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  cfg-headless = evalFor { nixrescue.enable = true; };

  guiStandIn = pkgs.writeShellApplication {
    name = "nixrescue-eval-test-session";
    text = "echo stand-in-session";
  };
  cfg-gui = evalFor {
    nixrescue = {
      enable = true;
      gui.package = guiStandIn;
    };
  };

  cfg-keys = evalFor {
    nixrescue = {
      enable = true;
      authorizedKeys = [ "ssh-ed25519 AAAAtest operator" ];
      ssh.enable = true;
    };
  };

  cfg-vault = evalFor {
    nixrescue = {
      enable = true;
      vault.device = "/dev/disk/by-partlabel/vault";
      vault.unlockTimeoutSec = 30;
    };
  };

  results = [
    (check "disabled by default" (!(evalFor { }).nixrescue.enable) "nixrescue.enable defaulted to true")

    (check "headless config builds with no per-materialisation input"
      (!(evalFailsBuild { nixrescue.enable = true; }))
      "a minimal enabled config should not trip any of the module's own assertions")

    (check "every rescue installs its authenticated release-info reader"
      (lib.any (p: (p.pname or p.name or "") == "nixrescue-release-info")
        cfg-headless.environment.systemPackages)
      "nixrescue-release-info must expose the UKI-supplied digest, size and init path")

    (check "the login banner points at authenticated identity, not a build timestamp"
      (lib.hasInfix "nixrescue-release-info" cfg-headless.environment.etc."motd".text
        && !(lib.hasInfix "built at" cfg-headless.environment.etc."motd".text))
      "motd must route to signed release identity rather than a source-coupled timestamp")

    (check "headless config installs no gui launcher"
      (!(lib.any (p: (p.pname or p.name or "") == "nixrescue-launch-gui") cfg-headless.environment.systemPackages))
      "nixrescue-launch-gui should not appear when gui.package is null")

    (check "gui.package pulls in both the package and the launcher"
      (lib.any (p: p == guiStandIn) cfg-gui.environment.systemPackages
        && lib.any (p: (p.pname or p.name or "") == "nixrescue-launch-gui") cfg-gui.environment.systemPackages)
      "expected both guiStandIn and nixrescue-launch-gui in environment.systemPackages")

    (check "vault.device with no gui installs no gui launcher"
      (!(lib.any (p: (p.pname or p.name or "") == "nixrescue-launch-gui") cfg-vault.environment.systemPackages))
      "nixrescue-launch-gui should not appear when gui.package is null, regardless of vault.device")

    (check "vault.device installs the unlock helper"
      (lib.any (p: (p.pname or p.name or "") == "nixrescue-unlock-vault") cfg-vault.environment.systemPackages)
      "nixrescue-unlock-vault should appear when vault.device is set")

    (check "authorizedKeys renders into root's real authorized_keys"
      (cfg-keys.users.users.root.openssh.authorizedKeys.keys == [ "ssh-ed25519 AAAAtest operator" ])
      "authorizedKeys should pass straight through to users.users.root.openssh.authorizedKeys.keys")

    (check "sshd is disabled by default in the cloneable rescue"
      (!cfg-headless.services.openssh.enable)
      "services.openssh.enable should stay false until a device class opts in")

    (check "TPM-gated sshd has no generated host-key fallback"
      (cfg-keys.services.openssh.hostKeys == [ ]
        && lib.hasInfix "nixboot-initrd-hostkey" cfg-keys.services.openssh.extraConfig
        && cfg-keys.systemd.services.sshd.serviceConfig.LoadCredentialEncrypted == [ "nixboot-initrd-hostkey" ])
      "enabled rescue sshd must consume only the stub-delivered encrypted credential")

    (check "enabling sshd without an operator key is refused"
      (evalFailsBuild {
        nixrescue = {
          enable = true;
          ssh.enable = true;
        };
      })
      "a TPM host identity without an authorized operator would be an unreachable open service")

    (check "the UKI menu title is nixrescue"
      (cfg-headless.system.nixos.extraOSReleaseArgs.PRETTY_NAME == "nixrescue")
      "the rescue os-release PRETTY_NAME must identify the boot entry as nixrescue")

    (check "the removed build timestamp has no compatibility surface"
      (evalFailsBuild {
        nixrescue = {
          enable = true;
          builtAt = "2026-01-01T00:00:00Z";
        };
      })
      "nixrescue.builtAt must stay removed: freshness belongs to signed delivery state")

    (check "vault.device must look like an absolute /dev path"
      (evalFailsBuild {
        nixrescue = {
          enable = true;
          vault.device = "not-a-device-path";
        };
      })
      "a vault.device that doesn't start with /dev/ should fail the module's own assertion")

    (check "disabled entirely renders no nixrescue config at all"
      (!(evalFor { nixrescue.enable = false; }).services.openssh.enable or false)
      "services.openssh.enable should not be forced on when nixrescue.enable is false")
  ];

  allResults = results;
  failed = builtins.filter (r: !r.ok) allResults;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixrescue eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length allResults)}):
    ${report}
  ''
else
  pkgs.runCommand "nixrescue-eval-tests"
  { passedCount = toString (builtins.length allResults); }
    ''
      echo "all $passedCount nixrescue eval tests passed"
      touch $out
    ''
