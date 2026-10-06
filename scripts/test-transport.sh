#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests
clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g \
  -I Sources/DSPBridge/include Sources/DSPBridge/bridge.c Tests/transport.c \
  -framework CoreAudio -o build/tests/transport
build/tests/transport
