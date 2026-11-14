# Preserve agent output-token limits

This consumer revision pins merged vMLX runtime61ad90ff83248492fac541cee7a52d6e99cf610b
(PR719), whose source tree is identical to tested heade7e883e34. It updates the runtime so an agent's explicit Max Tokens
value reaches both batch and solo generation unchanged. DeepSeek-V4.1 could
previously receive a million-token request and end at exactly11,387 tokens
because a historical Metal live-buffer estimate silently replaced its limit.

The runtime now reports buffer projections as advisory, leaves unavailable OS
resource limits unknown, and distinguishes V4.1's contiguous pools from the
historical per-token retention estimate. Explicit short limits and normal stop
tokens still apply. This does not promise a million-token answer or remove real
allocation failures, and does not change sampling, thinking, or model output.

Runtime validation:22 focused tests across5suites, including batch admission for
nil/1,000,000/8,12,001 actual constant-logit CPU iterator steps, explicit8-token
termination, and long V4.1 cache disk round trips. Consumer build and pin-contract
checks are pending. The synthetic fixture verifies limit handling, not full-model
DeepSeek quality, DSpark throughput, or million-token hardware capacity.
