#!/bin/bash -eu
#
# Build fuzz targets for ClusterFuzzLite.
# Uses the standard OSS-Fuzz environment variables:
#   $CC, $CFLAGS, $LIB_FUZZING_ENGINE, $OUT, $SRC

# Dis bytecode parser fuzz target
$CC $CFLAGS \
    -I"$SRC/infernode/include" \
    -I"$SRC/infernode/Linux/amd64/include" \
    -o "$OUT/fuzz_dis_parser" \
    "$SRC/infernode/.clusterfuzzlite/fuzz_dis_parser.c" \
    "$SRC/infernode/libinterp/load.c" \
    $LIB_FUZZING_ENGINE

# Seed corpus: real modules, committed, because dis/ is a build product a
# fresh clone does not have (INFR-438).  corpus/dis is the smallest set of
# modules from a full build that libFuzzer's -merge=1 kept, cut down to the
# ones that each add coverage: 47 modules, 303 edges of the parser at the
# start against 52 from the regression input alone.  Regenerate the same way
# when the Dis format changes.
mkdir -p "$OUT/fuzz_dis_parser_seed_corpus"
cp "$SRC/infernode/.clusterfuzzlite/corpus/dis/"*.dis "$OUT/fuzz_dis_parser_seed_corpus/"
# Regression inputs: malformed modules that once crashed the parser.
cp "$SRC/infernode/.clusterfuzzlite/regress/dis/"*.dis "$OUT/fuzz_dis_parser_seed_corpus/"

# 9P/Styx message parser fuzz target
$CC $CFLAGS \
    -I"$SRC/infernode/include" \
    -I"$SRC/infernode/Linux/amd64/include" \
    -o "$OUT/fuzz_9p_messages" \
    "$SRC/infernode/.clusterfuzzlite/fuzz_9p_messages.c" \
    "$SRC/infernode/lib9/convM2S.c" \
    "$SRC/infernode/lib9/convS2M.c" \
    $LIB_FUZZING_ENGINE

# Seed corpus: a few canonical 9P messages that exercise exportfs/devmnt framing.
mkdir -p "$OUT/fuzz_9p_messages_seed_corpus"
printf '\x13\x00\x00\x00\x64\xff\xff\x00\x20\x00\x00\x06\x009P2000' \
    > "$OUT/fuzz_9p_messages_seed_corpus/tversion.bin"
printf '\x14\x00\x00\x00\x6e\x01\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x00\x01\x00a' \
    > "$OUT/fuzz_9p_messages_seed_corpus/twalk.bin"
printf '\x16\x00\x00\x00\x6e\x01\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x00\x03\x00a/b' \
    > "$OUT/fuzz_9p_messages_seed_corpus/twalk-slash.bin"
printf '\x09\x00\x00\x00\x6c\x03\x00\x02\x00' \
    > "$OUT/fuzz_9p_messages_seed_corpus/tflush.bin"
printf '\x0f\x00\x00\x00\x75\x02\x00\x04\x00\x00\x00ABCD' \
    > "$OUT/fuzz_9p_messages_seed_corpus/rread.bin"
printf '\x05\x00\x00\x00\x6d\x00\x00' \
    > "$OUT/fuzz_9p_messages_seed_corpus/short-header.bin"
