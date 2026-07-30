{
  description = "The cold-mode rescue layer: a small, self-contained NixOS install on its own medium, materialised onto a cold device in front of any main, verified in CI before it ever ships.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Composes the repair toolchain onto both `checks` own rescue-shaped test configuration AND
    # `examples/rescue` (the real, generic `nixosConfigurations.rescue` this repo now ships) --
    # proving the real inter-repo composition this project's design record assumes, not a stand-in
    # for it. A consumer of nixrescue.nixosModules.default never needs to follow this input
    # themselves; the module takes `pkgs` from whatever evaluation composes it and never
    # references nixfs directly.
    nixfs.url = "github:julian-corbet/nixfs-corbet-ch";
    nixfs.inputs.nixpkgs.follows = "nixpkgs";

    # Used by `checks` only, to build the second UKI the real UEFI-boot VM
    # test (checks/rescue-uefi-boot-vm-test.nix) places on its synthetic ESP.
    # `nixboot.extraEntries` is the mechanism this project's own design
    # record named as the critical-path dependency for that harness
    # (docs/design.md, experiments/README.md #001) -- it has since landed
    # upstream, which is what makes that test possible at all. Same
    # boundary as nixfs above: a consumer of nixrescue.lib.mkMaintainer
    # never needs this input, since materialising bytes onto a device and
    # building/signing a UKI from them are deliberately two different
    # projects' jobs (see lib/mkMaintainer.nix's own header).
    nixboot.url = "github:julian-corbet/nixboot-corbet-ch";
    nixboot.inputs.nixpkgs.follows = "nixpkgs";

    # `examples/rescue`'s graphical session. Measures small (see
    # examples/rescue/configuration.nix's own comment for the real numbers) with zero
    # pipewire/llvm/ffmpeg in its closure -- the property that made it the pick over anything
    # already in nixpkgs for a closure sized to a fixed slot budget. A consumer of
    # `nixosModules.default` never needs this input either: `nixrescue.gui.package` is a bare
    # package pointer (see modules/nixrescue.nix), and this repo's own module names no compositor
    # -- only the EXAMPLE does, same as nixfs/nixboot above.
    nixscroll.url = "github:julian-corbet/nixscroll-corbet-ch";
    nixscroll.inputs.nixpkgs.follows = "nixpkgs";

    # NOT an input: nixdesktop. The three-layer model this family's other desktop consumers use
    # (a compositor repo owns its own config; nixdesktop owns policy plus a platform backend that
    # resolves roles into packages) is exactly right for a rescue too, in principle -- but at the
    # revision nixdesktop currently publishes, its policy profile still hardcodes
    # `compositor = "niri"` with no free-form role and no escape hatch for a compositor with no
    # nixpkgs package (scroll has none). Routing through it today would mean pulling niri itself
    # into this closure just to reach the `terminal` role, which is precisely the bloat picking
    # nixscroll for its size was meant to avoid. `examples/rescue/configuration.nix` therefore
    # names `nixscroll`'s package and a plain terminal directly for now; the moment nixdesktop
    # publishes a compositor-neutral policy+backend, that becomes the one-line swap the header
    # comment there describes, and this input slots in alongside nixfs/nixboot the same way.
    #
    # NOT an input: system-manager. Unlike nixfs/nixram, nixrescue's own
    # module never runs on a non-NixOS host at all -- the rescue is always
    # real NixOS, regardless of what the main in front of it is (see
    # modules/nixrescue.nix's header). The one piece a system-manager main
    # DOES call, `lib.mkMaintainer`, is a plain function with no module
    # system involved and needs nothing from that flake either.
  };

  outputs = { self, nixpkgs, nixfs, nixboot, nixscroll }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };

      # examples/rescue is x86_64-linux only -- the one architecture the hosts this project's
      # design record is written against actually run. Nothing about the mechanism is
      # architecture-specific; there is simply nothing aarch64 to point it at yet.
      rescueSystem = "x86_64-linux";

      # See lib/firmware.nix for the reviewable subtree list and the three verified traps its own
      # header documents.
      firmwareLib = import ./lib/firmware.nix { };
      curatedFirmware = firmwareLib.mkCuratedFirmware { pkgs = pkgsFor rescueSystem; };

      # The example's graphical session -- see the `nixscroll` input comment above for why this
      # is threaded straight through rather than routed via nixdesktop today.
      rescueGuiPackage = nixscroll.packages.${rescueSystem}.scroll;

      # A representative slot size for checks/rescue-image-fits-slot.nix below -- illustrative,
      # not a measurement taken off any real medium. A real consumer sizes its own slot to its own
      # medium and passes that value to the same check.
      exampleSlotSizeMiB = 1024;
    in
    {
      # The rescue's own option surface. Import this into a
      # `nixosConfigurations.<host>-rescue` -- NEVER into a main's own
      # configuration, which only ever calls `lib.mkMaintainer` below. See
      # modules/nixrescue.nix for the full SCOPE.
      nixosModules.nixrescue = ./modules/nixrescue.nix;
      nixosModules.default = self.nixosModules.nixrescue;

      # The mechanism a MAIN calls -- a plain function, not a module, so a
      # NixOS main and a system-manager main call it identically. See
      # lib/mkMaintainer.nix.
      lib.mkMaintainer = import ./lib/mkMaintainer.nix;

      # The firmware curation mechanism, exposed so a consumer can inspect or reuse the subtree
      # list without re-reading the file -- same reason nixfs exposes its own catalogue this way
      # (nixfs's `lib.catalogue`).
      lib.firmware = firmwareLib;

      # THE FIRST REAL, GENERIC nixosConfigurations.rescue -- an example, not a host. See
      # examples/rescue/configuration.nix for why nothing here is per-machine, and
      # docs/design.md for the design this composition implements pieces of.
      nixosConfigurations.rescue = lib.nixosSystem {
        system = rescueSystem;
        specialArgs = {
          nixfsLib = nixfs.lib;
          inherit curatedFirmware rescueGuiPackage;
        };
        modules = [
          self.nixosModules.nixrescue
          nixfs.nixosModules.default
          ./examples/rescue/configuration.nix
          ./examples/rescue/overlay-store.nix
        ];
      };

      # Buildable on its own (`nix build .#curatedFirmware`) so the curated set can be inspected --
      # or its size measured -- without pulling in the rest of the example toplevel.
      packages.${rescueSystem}.curatedFirmware = curatedFirmware;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixrescueModule = self.nixosModules.nixrescue;
          nixfsModule = nixfs.nixosModules.default;
          nixbootModule = nixboot.nixosModules.default;
          mkMaintainer = self.lib.mkMaintainer;
          # Only meaningful on rescueSystem -- see checks/default.nix's own handling of null.
          rescueToplevel =
            if system == rescueSystem
            then self.nixosConfigurations.rescue.config.system.build.toplevel
            else null;
          slotSizeMiB = exampleSlotSizeMiB;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
