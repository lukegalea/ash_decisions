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

**Early.** What exists today is the conformance harness (below) and the adoption decision it
settled. The Ash resource layer, the compiler, the publish-time analysis and the dmn-js
designer are being built on top of it.

## The engine is adopted, not written

The DMN and FEEL implementation is [Boxic](https://github.com/koenusz/boxic) —
`boxic_dmn` and `boxic_feel`, both Apache-2.0 and both on Hex. That was a measured decision
rather than a preference: writing a conforming FEEL implementation is a 60–90 person-day
project, and an independent run of the official conformance kit put Boxic at **97.68%**
before any work of ours.

What this package adds is everything the engine deliberately does not have: versioned
immutable definitions, multitenancy, the authorization model, the audit trail, publish-time
overlap and completeness analysis, and the designer.

## The conformance harness

`priv/tck/` is the [DMN TCK](https://github.com/dmn-tck/tck) corpus, vendored unmodified at a
pinned commit — 149 test groups across compliance levels 2 and 3, 3,495 asserted result
nodes. See `priv/tck/ATTRIBUTION.md`; the corpus is share-alike licensed and hash-guarded.

```bash
mix ash_decisions.tck            # run the corpus and gate on the result
mix ash_decisions.tck --failures # list everything that did not pass, grouped by cause
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

## Requirements

`boxic_dmn` validates documents against the normative XSD by shelling out to **`xmllint`**,
so `libxml2` must be on `PATH`. Without it every model fails to load with
`:schema_validator_unavailable`.

## Licence

MIT. The vendored TCK corpus keeps its own terms — see `priv/tck/ATTRIBUTION.md`.
