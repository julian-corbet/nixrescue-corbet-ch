# checks/eval-tests.nix
#
# EVAL-TIME tests for modules/nixrescue.nix and lib/mkMaintainer.nix. No VM,
# no build beyond the cheap derivations these two produce: every module test
# evaluates a full NixOS configuration (nixrescue needs the real option tree
# -- services.openssh, users.*, environment.* -- not a bare `evalModules`
# over its own options alone) and inspects what it RENDERS. See
# rescue-vm-test.nix for the one test that boots anything.

{ pkgs, nixpkgs, nixrescueModule, mkMaintainer }:

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

  cfg-headless = evalFor { nixrescue = { enable = true; builtAt = "2026-01-01T00:00:00Z"; }; };

  guiStandIn = pkgs.writeShellApplication {
    name = "nixrescue-eval-test-session";
    text = "echo stand-in-session";
  };
  cfg-gui = evalFor {
    nixrescue = {
      enable = true;
      builtAt = "2026-01-01T00:00:00Z";
      gui.package = guiStandIn;
    };
  };

  cfg-keys = evalFor {
    nixrescue = {
      enable = true;
      builtAt = "2026-01-01T00:00:00Z";
      authorizedKeys = [ "ssh-ed25519 AAAAtest operator" ];
    };
  };

  cfg-vault = evalFor {
    nixrescue = {
      enable = true;
      builtAt = "2026-01-01T00:00:00Z";
      vault.device = "/dev/disk/by-partlabel/vault";
      vault.unlockTimeoutSec = 30;
    };
  };

  results = [
    (check "disabled by default" (!(evalFor { }).nixrescue.enable) "nixrescue.enable defaulted to true")

    (check "headless config builds (no gui, no vault, builtAt set)"
      (!(evalFailsBuild { nixrescue = { enable = true; builtAt = "2026-01-01T00:00:00Z"; }; }))
      "a minimal enabled config should not trip any of the module's own assertions")

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

    (check "sshd is enabled by default once nixrescue is enabled"
      cfg-headless.services.openssh.enable
      "services.openssh.enable should default true under nixrescue.enable")

    (check "the UKI menu title is nixrescue"
      (cfg-headless.system.nixos.extraOSReleaseArgs.PRETTY_NAME == "nixrescue")
      "the rescue os-release PRETTY_NAME must identify the boot entry as nixrescue")

    (check "builtAt with no default: enabling without setting it is a build failure"
      (evalFailsBuild { nixrescue.enable = true; })
      "nixrescue.enable without nixrescue.builtAt should fail to build (no default, by design)")

    (check "vault.device must look like an absolute /dev path"
      (evalFailsBuild {
        nixrescue = {
          enable = true;
          builtAt = "2026-01-01T00:00:00Z";
          vault.device = "not-a-device-path";
        };
      })
      "a vault.device that doesn't start with /dev/ should fail the module's own assertion")

    (check "disabled entirely renders no nixrescue config at all"
      (!(evalFor { nixrescue.enable = false; }).services.openssh.enable or false)
      "services.openssh.enable should not be forced on when nixrescue.enable is false")
  ];

  # ── lib.mkMaintainer: a plain function, no module system, checked directly ──
  maintainerResult = mkMaintainer {
    inherit pkgs;
    name = "eval-test-target";
    toplevel = pkgs.writeText "fake-toplevel" "not a real closure, only used to check the function's own shape";
    device = "/dev/disk/by-partlabel/rescue-eval-test";
    onCalendar = "weekly";
  };

  maintainerResults = [
    (check "mkMaintainer returns a plain attrset, not a module"
      (!(maintainerResult ? _type) && !(maintainerResult ? options))
      "the result should be an ordinary attrset with no module-system markers")

    (check "mkMaintainer.service is ready to assign to systemd.services.<name> as-is"
      (maintainerResult.service.serviceConfig.Type == "oneshot"
        && lib.hasInfix "nixrescue-maintain-eval-test-target" maintainerResult.service.serviceConfig.ExecStart)
      "service.serviceConfig should point ExecStart at the built script")

    (check "mkMaintainer.timer honours the onCalendar argument"
      (maintainerResult.timer.timerConfig.OnCalendar == "weekly")
      "onCalendar should pass straight through to timer.timerConfig.OnCalendar")

    (check "mkMaintainer.timer defaults OnCalendar to daily when unset"
      ((mkMaintainer {
        inherit pkgs;
        name = "eval-test-default";
        toplevel = pkgs.writeText "fake-toplevel-2" "unused";
        device = "/dev/disk/by-partlabel/rescue-eval-test-2";
      }).timer.timerConfig.OnCalendar == "daily")
      "onCalendar's own default should be \"daily\"")
  ];

  allResults = results ++ maintainerResults;
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
