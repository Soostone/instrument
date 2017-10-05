set -e
cabal sandbox init

ROOT=$SOOSTONE_CODE_DIR/sage

cabal sandbox add-source $ROOT/deps/instrument
cabal sandbox add-source $ROOT/deps/amazonka/amazonka
