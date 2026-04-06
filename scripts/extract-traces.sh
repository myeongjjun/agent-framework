#!/bin/bash
exec python3 "$(dirname "$0")/extract-traces.py" "$@"
