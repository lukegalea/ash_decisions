# AshDecisions

**Business rules as versioned, tenant-scoped, auditable Ash resources — expressed in DMN.**

A decision that routes an approval, prices a contract or classifies a risk is configuration,
not code: it changes on a business timescale, it is authored by people who do not deploy, and
when it changes an auditor wants to know *which version* decided *which case*. `ash_decisions`
holds those decisions as DMN documents, compiles each into an immutable versioned snapshot,
evaluates it with a native FEEL engine, and records what fired.

It is the decision half of the pair that `ash_bpmn` completes: the process graph orchestrates
and never decides; a business rule task hands the deciding to a decision.

## Status

**Early, and specific about it.** What exists and is under test:

- **`AshDecisions.Resources.Definition`** — versioned DMN definitions with a
  `draft → published → retired` lifecycle, at most one draft per key, and a publish that
  refuses to run over a compile error.
- **`AshDecisions.Resources.Evaluation`** — an append-only row per invoked decision: inputs,
  outputs, which rules matched, how long it took, and the failure when there was one.
- **`AshDecisions.Compiler`** — DMN in, immutable JSON snapshot out, with an explicit list of
  constructs it refuses by element id rather than skipping quietly.
- **`AshDecisions.Feel`** — the single module that touches the FEEL engine, with a killed-process
  timeout and size and depth bounds on every tenant-authored expression.
- **`AshDecisions.Scope`** and the generated authorization bypass, tenancy via `tenant?: true`,
  and `:base` for sitting on a host application's base resource.

What does **not** exist yet: **publish-time overlap and completeness analysis**. It is designed —
the technique is finite-domain enumeration and interval algebra over S-FEEL unary tests, with the
undecidable remainder carried as obligations re-checked at runtime — and none of it is built. The
`simple_sat` dev dependency is declared for it and currently unused. Also absent: any way to
evaluate a decision against sample inputs *from the editor*, so an author publishes without
having watched the table fire; and `matched_rule_ids` is always empty, because
`Boxic.DMN.evaluate/3` reports what a decision returned but not which rule produced it — a real
hole in the audit story, and upstream.

## The engine is adopted, not written

The DMN and FEEL implementation is [Boxic](https://github.com/koenusz/boxic) —
`boxic_dmn` and `boxic_feel`, both Apache-2.0 and both on Hex. That was a measured decision
rather than a preference: writing a conforming FEEL implementation is a 60–90 person-day
project, and an independent run of the official conformance kit put Boxic at **97.68%**
before any work of ours.

What this package adds is everything the engine deliberately does not have: versioned
immutable definitions, multitenancy, the authorization model, the audit trail, and the dmn-js
designer. Publish-time overlap and completeness analysis belongs on that list and is not on it
yet — see above. Listing it here as though it shipped is exactly the drift this README should
not have, and did.

## The conformance harness

`priv/tck/` is the [DMN TCK](https://github.com/dmn-tck/tck) corpus, vendored unmodified at a
pinned commit — 146 test groups across compliance levels 2 and 3, 3,495 asserted result
nodes. See `priv/tck/ATTRIBUTION.md`; the corpus is share-alike licensed and hash-guarded.

```bash
mix ash_decisions.tck            # run the corpus and gate on the result
mix ash_decisions.tck --failures # list everything that did not pass, grouped by cause
mix ash_decisions.tck --downgrade # same run against DMN 1.3, the revision dmn-js writes
mix ash_decisions.tck.verify     # prove the vendored corpus is unmodified
```

The run reports four outcomes rather than a single pass rate, because a conformance number is
only useful if it separates *the engine got the wrong answer* from *we never asked*:

| Outcome | Meaning |
|---|---|
| `passed` | The result matched the expectation. |
| `failed` | The engine answered, and answered wrong. **This is the number that matters.** |
| `model_error` | The model would not load or validate, so nothing in it was evaluated. |
| `harness_error` | *This* code could not read the expectation file. Ours to fix. |

`AshDecisions.Tck.ExpectedFailures` lists every group that does not pass and why. The task
fails if something fails that is not listed — and **also** if something listed starts
passing, so the list can only shrink.

### Where it stands

```
compliance-level-2      122/126    96.83%
compliance-level-3     3292/3369   97.71%
all levels             3414/3495   97.68%
```

The 81 outstanding nodes are four things, none of them a wrong answer to a well-formed
question: external Java functions (deliberately unsupported — a DMN model reaching into
`java.lang.Math` is tenant-authored code execution); a validator stricter than the schema
about optional `id` and `locationURI` attributes; last-digit disagreement in exponentiation
across the loan-amortisation groups; and one decision-service result-shape difference.

## The DMN revision gap, and how it is closed

Two halves of the toolchain disagree about which DMN they speak:

- **`dmn-js`**, the bpmn.io modeller and the only serious browser DMN editor, has emitted
  **DMN 1.3** since its 8.0.0 release and still does at 17.x.
- **`boxic_dmn`**, the engine, loads **DMN 1.5** and refuses anything else with
  `:dmn_version_mismatch`.

So a document drawn in the designer is rejected by the engine that has to run it.
`AshDecisions.Dmn.Profile` closes that on the way *into* the engine by rewriting the MODEL and
FEEL namespace URIs, and nothing else — no element added, removed, renamed or reordered. The
stored document is never touched, because `content_hash` is what says a snapshot and a
document belong together.

The safety of that rewrite is **measured, not argued**. The vendored corpus is entirely DMN
1.5, so `mix ash_decisions.tck --downgrade` rewrites every model to the 1.3 namespaces first
and re-runs the whole suite. Identical numbers with and without it — 3414/3495 both ways —
is the claim.

It also means the conformance number is a statement about DMN 1.5 documents specifically:
that is what upstream ships, and there is no 1.2/1.3/1.4 corpus to measure against.

## Requirements

`boxic_dmn` validates documents against the normative XSD by shelling out to **`xmllint`**,
so `libxml2` must be on `PATH`. Without it every model fails to load with
`:schema_validator_unavailable`.

## Licence

MIT. The vendored TCK corpus keeps its own terms — see `priv/tck/ATTRIBUTION.md`.
