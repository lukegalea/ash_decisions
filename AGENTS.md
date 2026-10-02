<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_decisions`, business rules as versioned, tenant-scoped,
auditable Ash resources, expressed in DMN.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- The engine is adopted, not written. DMN and FEEL come from Boxic
  (`boxic_dmn`, `boxic_feel`). This package adds versioned definitions,
  tenancy, authorization, the audit trail, publish-time verification, and the
  dmn-js designer.
- `AshDecisions.Feel` is the single module that touches the FEEL engine.
- `priv/tck/` is the DMN TCK corpus, vendored unmodified at a pinned commit.
  Do not edit those files. `mix ash_decisions.tck.verify` proves that the
  corpus is unmodified.
- `AshDecisions.Tck.ExpectedFailures` can only shrink. `mix ash_decisions.tck`
  fails if a listed group starts to pass.
- The stored DMN document is never rewritten. `content_hash` binds a snapshot
  to its document.
- `boxic_dmn` needs `xmllint` (`libxml2`) on `PATH`.
- Changes are judged against the 26 Iron Laws. Read "Iron laws" in
  `usage-rules.md`.

## Before you finish

CI runs `mix compile --force --warnings-as-errors`, `mix test`,
`mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix docs`,
`mix deps.unlock --check-unused`, `mix deps.audit`, and a REUSE check. Run them
before you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
