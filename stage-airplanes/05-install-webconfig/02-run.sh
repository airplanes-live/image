#!/bin/bash -e
# Stage 05 has no source-tree clones to clean up — the webconfig source lives
# permanently in image/webconfig/ on the build host and is consumed by the
# cross-build in 00-run.sh. This script exists so pi-gen's stage runner finds
# the expected file shape.
:
