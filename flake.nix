{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    devenv.url = "github:kadena-io/devenv/devnet-setup";
    chainweb-node.url = "github:kadena-io/chainweb-node/edmund/fast-devnet";
    chainweb-node-l2.url = "github:kadena-io/chainweb-node/edmund/l2-spv-poc";
    chainweb-data = {
      url = "github:kadena-io/chainweb-data/enis/extra-migrations-folder";
      inputs.nixpkgs.follows = "chainweb-node/nixpkgs";
      inputs.haskellNix.follows = "chainweb-node/haskellNix";
    };
    chainweb-mining-client = {
      url = "github:kadena-io/chainweb-mining-client/enis/update-to-flakes-and-haskellNix";
      inputs.haskellNix.follows = "chainweb-node/haskellNix";
      inputs.nixpkgs.follows = "chainweb-node/nixpkgs";
    };
    nix-exe-bundle = { url = "github:3noch/nix-bundle-exe"; flake = false; };
  };

  outputs = { self
            , nixpkgs
            , devenv
            , ... } @ inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system: let
      overlay = (self: super: {
        chainweb-data = bundle inputs.chainweb-data.packages.${system}.default;
        chainweb-mining-client = bundle inputs.chainweb-mining-client.packages.${system}.default;
        chainweb-node = bundle inputs.chainweb-node.packages.${system}.default;
      });
      chainweb-node-l2 = bundle inputs.chainweb-node-l2.packages.${system}.default;
      pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
      bundle = pkgs.callPackage inputs.nix-exe-bundle {};
      modules = [
        modules/chainweb-data.nix
        modules/chainweb-node.nix
        modules/chainweb-mining-client.nix
        modules/http-server.nix
        modules/ttyd.nix
        modules/landing-page/module.nix
        ({config, ...}: {
          # https://devenv.sh/reference/options/
          process.implementation = "process-compose";
          devenv.root = ".";
        })
      ];
      containerExtras = with pkgs.lib; {config, ...}:{
        services.chainweb-data.extra-migrations-folder = "/cwd-extra-migrations";
        sites.landing-page.container-api.enable = true;
        sites.landing-page.container-api.ports = concatStringsSep "\n" (flatten [
          "- `8080`: Public HTTP API"
          (optional config.services.chainweb-node.enable
            "- `${toString config.services.chainweb-node.service-port}`: Chainweb node's service port"
          )
          (optional config.services.chainweb-data.enable
            "- `${toString config.services.chainweb-data.port}`: Chainweb data API port"
          )
        ]);
        sites.landing-page.container-api.folders = concatStringsSep "\n" (flatten [
          (optional config.services.chainweb-data.enable
            "- `/cwd-extra-migrations`: `chainweb-data`'s extra migrations folder"
          )
        ]);
      };
      mkFlake = extraModule:
        import ./mkDevnetFlake.nix {
          inherit pkgs nixpkgs devenv containerExtras;
          modules = modules ++ [extraModule];
        };
      configurations = let
        minimal = {
          services.chainweb-node.enable = true;
          services.chainweb-mining-client.enable = true;
          services.http-server.enable = true;
        };
        common = {
          imports = [minimal];
          services.chainweb-data.enable = true;
          services.ttyd.enable = true;
        };
        use-cwn-l2 = {
          services.chainweb-node.package = chainweb-node-l2;
        };
      in {
        default = common;
        l2 = { imports = [common use-cwn-l2]; };
        minimal = minimal;
      };
      combined-flake = import lib/combine-flakes.nix pkgs.lib (
        builtins.mapAttrs (_: config: mkFlake config) configurations
      );
      in pkgs.lib.recursiveUpdate combined-flake {
        apps.develop-page = {
          type = "app";
          program = (import ./lib/develop-page.nix {inherit pkgs;}).outPath;
        };
        inherit configurations;
        overlays.default = overlay;
        lib.mkFlake = mkFlake;
      });
}
