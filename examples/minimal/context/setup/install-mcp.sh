#!/usr/bin/env bash
#
# Referenced by [setup "mcp-servers"] in graft.conf.
#
# graft PRINTS this path after a successful run. It never executes it - that is
# invariant I1. You run it yourself, after reading it, which is exactly the
# review step that a tool auto-running scripts from a cloned repo would skip.
set -euo pipefail

echo "This is where your MCP server setup would go."
echo "graft did not run this. A human did."
