#!/bin/bash
# May be sourced by build/test/install without preparing or modifying dependencies.
PYTHON="${BOZHOU_PYTHON:-python3}"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ is required (set BOZHOU_PYTHON to select it)"'
