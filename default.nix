let sources = import ./nix/sources.nix;
in { ghc ? "ghc927", pkgs ? import sources.nixpkgs {
  config = {
    allowBroken = true;
    allowUnfree = true;
  };
} }:
with pkgs;
let

  inherit (pkgs) callPackage;
  inherit (pkgs.lib) composeExtensions sourceByRegex;
  inherit (pkgs.haskell.lib) dontCheck justStaticExecutables;

  ############################################################################
  # Haskell package set overlay containing overrides for newer packages than
  # are included in the base nixpkgs set as well as additions from vendored
  # or external source repositories.
  haskellPkgSetOverlay =
    pkgs.callPackage ./nix/haskell/overlay.nix { inherit sources; };

  # Haskell package set overlay providing 'instrument' packages.
  instrumentOverlay = pkgs.callPackage ./instrument/default.nix { };
  instrumentCloudwatchOverlay =
    pkgs.callPackage ./instrument-cloudwatch/default.nix { };

  ############################################################################
  # Construct a 'base' Haskell package set
  baseHaskellPkgs = pkgs.haskell.packages.${ghc};

  # Makes overlays given a base haskell package set. Can be used by
  # other projects
  haskellOverlays =
    [ haskellPkgSetOverlay instrumentOverlay instrumentCloudwatchOverlay ];

  # Construct the final Haskell package set
  haskellPkgs = baseHaskellPkgs.override (old: {
    overrides = builtins.foldl' composeExtensions (old.overrides or (_: _: { }))
      haskellOverlays;
  });

in {
  inherit haskellPkgs;
  inherit pkgs;
  inherit sources;
  inherit haskellOverlays;
}
