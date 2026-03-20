{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
    vimdoc-language-server.url = "github:barrettruth/vimdoc-language-server";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      vimdoc-language-server,
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs (import systems);
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      mkPythonEnv =
        pkgs:
        pkgs.python312.withPackages (ps: [
          ps.backoff
          ps.beautifulsoup4
          ps.httpx
          ps.ndjson
          ps.pydantic
          ps.requests
        ]);

      mkDevPythonEnv =
        pkgs:
        pkgs.python312.withPackages (ps: [
          ps.backoff
          ps.beautifulsoup4
          ps.httpx
          ps.ndjson
          ps.pydantic
          ps.requests
          ps.pytest
          ps.pytest-mock
        ]);

      mkSubmitEnv =
        pkgs:
        pkgs.buildFHSEnv {
          name = "cp-nvim-submit";
          targetPkgs =
            pkgs: with pkgs; [
              uv
              alsa-lib
              at-spi2-atk
              cairo
              cups
              dbus
              fontconfig
              freetype
              gdk-pixbuf
              glib
              gtk3
              libdrm
              libxkbcommon
              mesa
              libGL
              nspr
              nss
              pango
              libx11
              libxcomposite
              libxdamage
              libxext
              libxfixes
              libxrandr
              libxcb
              at-spi2-core
              expat
              libgbm
              systemdLibs
              zlib
            ];
          runScript = "${pkgs.uv}/bin/uv";
        };

      mkPlugin =
        pkgs:
        let
          pythonEnv = mkPythonEnv pkgs;
          submitEnv = mkSubmitEnv pkgs;
        in
        pkgs.vimUtils.buildVimPlugin {
          pname = "cp-nvim";
          version = "0-unstable-${self.shortRev or self.dirtyShortRev or "dev"}";
          src = self;
          postPatch = ''
            substituteInPlace lua/cp/utils.lua \
              --replace-fail "local _nix_python = nil" \
              "local _nix_python = '${pythonEnv.interpreter}'"
            substituteInPlace lua/cp/utils.lua \
              --replace-fail "local _nix_submit_cmd = nil" \
              "local _nix_submit_cmd = '${submitEnv}/bin/cp-nvim-submit'"
          '';
          nvimSkipModule = [
            "cp.pickers.telescope"
            "cp.version"
          ];
          passthru = { inherit pythonEnv submitEnv; };
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
        submitEnv = mkSubmitEnv (pkgsFor system);
      });

      formatter = eachSystem (system: (pkgsFor system).nixfmt-tree);

      devShells = eachSystem (system: {
        default = (pkgsFor system).mkShell {
          packages = with (pkgsFor system); [
            uv
            (mkDevPythonEnv (pkgsFor system))
            prettier
            ruff
            stylua
            neovim
            selene
            lua-language-server
            ty
            vimdoc-language-server.packages.${system}.default
          ];
        };
      });
    };
}
