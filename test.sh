#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
swiftc -D TESTING -framework Cocoa -framework IOKit -framework Metal -framework MetalKit -framework QuartzCore -framework CoreImage -framework ScreenCaptureKit -framework ServiceManagement Sources/*.swift Tests/Check.swift -o build/check
build/check
