{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs (import systems);
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      mkPythonEnv =
        pkgs:
        pkgs.python312.withPackages (ps: [
          ps.backoff
          ps.beautifulsoup4
          ps.curl-cffi
          ps.httpx
          ps.ndjson
          ps.pydantic
          ps.requests
        ]);

      mkPlugin =
        pkgs:
        let
          pythonEnv = mkPythonEnv pkgs;
        in
        pkgs.vimUtils.buildVimPlugin {
          pname = "cp-nvim";
          version = "0-unstable-${self.shortRev or self.dirtyShortRev or "dev"}";
          src = self;
          postPatch = ''
            substituteInPlace lua/cp/utils.lua \
              --replace-fail "local _nix_python = nil" \
              "local _nix_python = '${pythonEnv.interpreter}'"
          '';
          nvimSkipModule = [
            "cp.pickers.telescope"
            "cp.version"
          ];
          passthru = { inherit pythonEnv; };
          meta.description = "Competitive programming plugin for Neovim";
        };
    in
    {
      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // {
          cp-nvim = mkPlugin final;
        };
      };

      packages = eachSystem (system: {
        default = mkPlugin (pkgsFor system);
        pythonEnv = mkPythonEnv (pkgsFor system);
      });

      devShells = eachSystem (system: {
        default = (pkgsFor system).mkShell {
          packages = with (pkgsFor system); [
            uv
            python312
            prettier
            stylua
            selene
            lua-language-server
          ];
        };
      });
    };
}
