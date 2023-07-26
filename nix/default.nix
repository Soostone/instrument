let
  sources = import ./sources.nix;
in

rec {
  # All of our overlays, consolidated together into a single list.
  overlays = import ./overlays;

  # Args to apply to any nixpkgs to generate a package set with the overlays.
  nixpkgsArgs = { inherit overlays; };

  # A pinned version of nixpkgs, widely used and hopefully well cached.
  defaultNixpkgs = import sources.nixpkgs;

  # A package set for the specified system, based on `defaultNixpkgs`, with
  # additional arguments and all overlays applied.
  pkgSetForSystem =
    system: args: defaultNixpkgs (args // nixpkgsArgs // { inherit system; });

  # `pkgSetForSystem` for the current system.
  pkgSet = args: pkgSetForSystem builtins.currentSystem args;

  inherit sources;
}
