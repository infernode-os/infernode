#!/bin/bash -eu
#
# Build fuzz targets for ClusterFuzzLite.
# Uses the standard OSS-Fuzz environment variables:
#   $CC, $CFLAGS, $LIB_FUZZING_ENGINE, $OUT, $SRC

# Dis bytecode parser fuzz target
$CC $CFLAGS \
    -o "$OUT/fuzz_dis_parser" \
    "$SRC/infernode/.clusterfuzzlite/fuzz_dis_parser.c" \
    $LIB_FUZZING_ENGINE

# Seed corpus: existing .dis bytecode files from the runtime tree
mkdir -p "$OUT/fuzz_dis_parser_seed_corpus"
find "$SRC/infernode/dis" -name '*.dis' -size -64k | head -50 | while read -r f; do
    cp "$f" "$OUT/fuzz_dis_parser_seed_corpus/"
done

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
printf '\x09\x00\x00\x00\x6c\x03\x00\x02\x00' \
    > "$OUT/fuzz_9p_messages_seed_corpus/tflush.bin"
printf '\x0f\x00\x00\x00\x75\x02\x00\x04\x00\x00\x00ABCD' \
    > "$OUT/fuzz_9p_messages_seed_corpus/rread.bin"
