{ haskell, lib, sources }:

# In-order:
#   - the 'final', or fixed-point, Haskell package set environment resulting
#     from the application of this overlay as well as any others it may be
#     composed with
#   - the 'previous' Haskell package set environment that this overlay will have
#     been composed with
#
# Practically speaking:
#   - 'hfinal' can be used to operate over the resulting package set that this
#     overlay may be used to create, however if one is not careful they can
#     cause an infinitely recursive definition by defining something in terms of
#     itself
#   - 'hprev' can be used to operate over the package set environment as it
#     existed strictly _before_ this overlay will have been applied; it can't
#     use the final package set in any way, but it also can't infinitely recurse
#     upon itself
hfinal: hprev:

let inherit (haskell.lib) doJailbreak dontCheck;

in {
  amazonka = dontCheck
    (hfinal.callCabal2nix "amazonka" (sources.amazonka + "/lib/amazonka") { });

  amazonka-core = dontCheck (hfinal.callCabal2nix "amazonka-core"
    (sources.amazonka + "/lib/amazonka-core") { });

  amazonka-cloudwatch = dontCheck (hfinal.callCabal2nix "amazonka-cloudwatch"
    (sources.amazonka + "/lib/services/amazonka-cloudwatch") { });

  amazonka-sts = dontCheck (hfinal.callCabal2nix "amazonka-sts"
    (sources.amazonka + "/lib/services/amazonka-sts") { });

  amazonka-sso = dontCheck (hfinal.callCabal2nix "amazonka-sso"
    (sources.amazonka + "/lib/services/amazonka-sso") { });

  amazonka-test = dontCheck (hfinal.callCabal2nix "amazonka-test"
    (sources.amazonka + "/lib/amazonka-test") { });

  safecopy-hunit = dontCheck
    (hfinal.callCabal2nix "safecopy-hunit" sources.safecopy-hunit { });

}
