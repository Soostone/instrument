{ withHoogle ? true, withCommitHook ? true }:
with (import ./. { });

let
  python-commit-hooks =
    pkgs.python3Packages.pre-commit-hooks.overridePythonAttrs
    (_: { doCheck = false; });
  pre-commit-hooks = import sources.pre-commit-hooks;
  pre-commit-config = if withCommitHook then {
    src = ./.;
    tools = pkgs;
    settings = {
      ormolu = {
        defaultExtensions = [
          "TypeApplications"
          "BangPatterns"
          "CPP"
          "QuasiQuotes"
          "TemplateHaskell"
        ];
      };
    };
    hooks = {
      ormolu.enable = true;
      hlint.enable = true;
      yamllint.enable = true;
      nixfmt = {
        enable = true;
        excludes = [ "nix/default.nix" ];
      };
      trailing-whitespace = {
        enable = true;
        name = "trailing-whitespace";
        entry = "${python-commit-hooks}/bin/trailing-whitespace-fixer";
        types = [ "text" ];
      };
      end-of-file = {
        enable = true;
        name = "end-of-file";
        entry = "${python-commit-hooks}/bin/end-of-file-fixer";
        types = [ "text" ];
      };
    };
  } else {
    src = ./.;
  };
  pre-commit-check = pre-commit-hooks.run pre-commit-config;
  # hls = (builtins.getFlake "github:haskell/haskell-language-server/2.0.0.0").packages.${builtins.currentSystem}.haskell-language-server-927;

in haskellPkgs.shellFor {
  packages = p: with p; [ p.instrument p.instrument-cloudwatch ];
  inherit withHoogle;

  nativeBuildInputs = with pkgs; [
    cabal-install
    ghcid
    # hls
    hlint
    hpack
    niv
    ormolu
  ];

  shellHook = ''
    { ${pre-commit-check.shellHook} } 2> /dev/null
  '';
}
