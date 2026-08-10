# LegacyCapabilities suite

Compatibility-only prompt-surface coverage for the deprecated
`capabilities_discover` / `capabilities_load` contract.

These cases keep old experiment profiles decodable while excluding their
zero-value gateway assumptions from the production PromptSurface and minimal
harness market lanes. New workspace-contract coverage belongs in
`PromptSurface` and should target deterministic query preflight or the compact
`capabilities` gateway.
