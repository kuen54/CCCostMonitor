#!/bin/bash
# Fix swiftc "redefinition of module 'SwiftBridging'" by moving aside the
# conflicting Command Line Tools modulemap. Requires sudo.
set -euo pipefail

MODULEMAP="/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap"

if [ ! -f "$MODULEMAP" ]; then
    echo "Nothing to do: $MODULEMAP does not exist (already moved?)"
    exit 0
fi

sudo mv "$MODULEMAP" "$MODULEMAP.bak"

if [ -e "$MODULEMAP" ]; then
    echo "FAIL: $MODULEMAP still exists after move" >&2
    exit 1
fi
echo "OK: moved $MODULEMAP -> $MODULEMAP.bak"
