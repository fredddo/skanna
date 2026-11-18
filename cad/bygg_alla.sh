#!/bin/zsh
# Bygg om alla delar för en skanning: nederskal (referens) först, sedan konstruktionsdelarna.
set -e
cd "$(dirname "$0")/.."
S="${1:?skanningsmapp}"
.venv/bin/python cad/nederskal.py "$S"
.venv/bin/python cad/provring.py "$S"
.venv/bin/python cad/overskal.py "$S"
