{
  withHoogle ? true,
  withCommitHook ? true,
}:
with (import ./. {}); let
  python-commit-hooks =
    pkgs.python3Packages.pre-commit-hooks.overridePythonAttrs
    (_: {doCheck = false;});
  pre-commit-hooks = import sources.pre-commit-hooks;
  pre-commit-config =
    if withCommitHook
    then {
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
    }
    else {
      src = ./.;
    };
  pre-commit-check = pre-commit-hooks.run pre-commit-config;
  # hls = (builtins.getFlake "github:haskell/haskell-language-server/2.0.0.0").packages.${builtins.currentSystem}.haskell-language-server-927;
in
  haskellPkgs.shellFor {
    packages = p: with p; [p.instrument p.instrument-cloudwatch];
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
