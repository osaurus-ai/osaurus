# Agent Creation Eval Suite

The first message of a New Agent chat, run through the shared agent loop
(`AgentLoopEvaluator` with the Configurator's agent id and a fresh draft
bound to the session, so the real New Agent prompt and its tool surface
are composed). `AgentCreationEvalHarness` scores the draft it leaves:

- the Configurator drafted through `agent_draft` `patch` and never called
  `osaurus_config`;
- the draft has a name and instructions, the capabilities the job needs
  are on (`capabilitiesOn`) and the ones it does not need stay off
  (`capabilitiesOff`), and the tool mode matches (`toolMode`);
- a name the person typed in the panel first (`handEditedName`) is kept;
- no agent was added and the reply never claims one was created;
- `clarify` stayed within `maxClarifications`.

`replies` answer `clarify` calls in order. Every row records end-to-end
tok/s and keeps the transcript.
