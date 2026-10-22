# Bundle-declared native reasoning modes

Diplodocus Preview4 declares think=reasoning_effort high and no_think=reasoning_effort low. It does not read enable_thinking. Previously the picker offered None/Low/High: None sent enable_thinking=false, leaving its native high default active, while Low selected the actual Off rail but was labelled as a lower effort.

The app now recognizes the explicit two-mode metadata contract and offers None (Off)/High. It sends exactly reasoning_effort low/high, preserves saved/native low requests as Off, and does not synthesize a request when the user leaves the choice unset. The mapping requires declared think/no_think modes, matching closed native efforts, supported transport and an explicit default mode; a plain low/high list retains its existing semantics. No model-name heuristic, template change, sampler override or reasoning close/open injection. Fixed-native-only contracts, Qwen low/medium/xhigh and Nemotron on/medium/off keep their existing paths.

Focused regression tests cover exact kwargs on UI/native API/legacy toggle paths, required-tool context, saved option migration, omitted controls and the negative plain-list case. Current actual app proof and test run are pending; do not call this merge-ready until they are recorded on the PR. The unrelated engine checkpoint pin retains865691945. No release/tag.
