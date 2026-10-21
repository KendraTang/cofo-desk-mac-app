#!/bin/bash
# Runs the Swift Testing suite with Command Line Tools (see Package.swift).
set -eu
cd "$(dirname "$0")"
exec swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks "$@"
