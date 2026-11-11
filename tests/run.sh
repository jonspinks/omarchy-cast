#!/usr/bin/env bash
# The pairing-code field's typing, under node and qmltestrunner.
set -euo pipefail
cd "$(dirname "$0")/.."
node tests/typing.test.js
qmltest=/usr/lib/qt6/bin/qmltestrunner
if [[ -x $qmltest ]]; then QT_QPA_PLATFORM=offscreen "$qmltest" -silent -input tests/qml; else echo "skip: no qmltestrunner (qt6-declarative)"; fi
