# Override uEnv.txt for minimal image builds.
# Priority 14 > meta-edgeai (13), so our file is found first in FILESPATH.
# The plain (no-subdir) uEnv.txt below is matched before edgeai's j721e/uEnv.txt.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
