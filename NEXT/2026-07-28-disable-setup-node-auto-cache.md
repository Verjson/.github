# Disable setup-node automatic cache discovery — 2026-07-28

Disabled setup-node's package-manager auto-cache path in the reusable Node
workflows and composite action so caching is controlled only by the explicit
cache input and matching lockfile contract (#152).
