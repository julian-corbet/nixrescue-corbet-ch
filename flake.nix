{
  description = "The cold-mode rescue layer: a small, self-contained NixOS install on its own medium, materialised onto a cold device in front of any main, verified in CI before it ever ships.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Used by `checks` only, to compose the repair toolchain onto the test
    # VM's own rescue-shaped configuration -- proving the real inter-repo
    # composition this project's design record assumes, not a stand-in for
    # it. A consumer of nixrescue.nixosModules.default never needs to follow
    # this input themselves; the module takes `pkgs` from whatever
    # evaluation composes it and never references nixfs directly.
    nixfs.url = "github:julian-corbet/nixfs-corbet-ch";
    nixfs.inputs.nixpkgs.follows = "nixpkgs";

    # NOT an input: system-manager. Unlike nixfs/nixram, nixrescue's own
    # module never runs on a non-NixOS host at all -- the rescue is always
    # real NixOS, regardless of what the main in front of it is (see
    # modules/nixrescue.nix's header). The one piece a system-manager main
    # DOES call, `lib.mkMaintainer`, is a plain function with no module
    # system involved and needs nothing from that flake either.
  };

  outputs = { self, nixpkgs, nixfs }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
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

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixrescueModule = self.nixosModules.nixrescue;
          nixfsModule = nixfs.nixosModules.default;
          mkMaintainer = self.lib.mkMaintainer;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
