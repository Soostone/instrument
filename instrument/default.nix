{ lib, haskell }:

hfinal: hprev:

let
  instrument = let
    inherit (hfinal) callCabal2nix;
    src = lib.sourceByRegex ./. [ "^src.*$" "^test.*$" "package.yaml" ];
  in callCabal2nix "instrument" src { };

in { inherit instrument; }
