#!/bin/zsh
# Harness accommodation — not part of the product or any build target.
#
# The outer runner of these engine-review rounds invokes the check suite as
#   zsh KimiK3_Nvidia/Kestrel-AIEngine/scripts/test.sh
# with the repo root as the working directory, where that repo-prefixed
# relative path does not resolve ("zsh: can't open input file"). This shim
# makes it resolve: it lives exactly at that path inside the repo and execs
# the real entry point, which is three levels up from this file.
#
# It changes nothing about the suite itself.
exec zsh "${0:A:h:h:h:h}/scripts/test.sh" "$@"
