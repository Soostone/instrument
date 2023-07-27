{ lib, haskell }:

hfinal: hprev:

let
  instrument-cloudwatch = let
    inherit (hfinal) callCabal2nix;
    src = lib.sourceByRegex ./. [ "^src.*$" "^test.*$" "package.yaml" ];
  in callCabal2nix "instrument-cloudwatch" src { };

in { inherit instrument-cloudwatch; }
