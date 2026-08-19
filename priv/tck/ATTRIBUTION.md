# Vendored: the DMN Technology Compatibility Kit

This directory is a **frozen, vendored copy of third-party content**. Do not edit anything
in it — see "Why it must not be edited" below, which is a licence obligation here and not
merely a convention.

## What it is

The test corpus of the [DMN TCK](https://github.com/dmn-tck/tck), the community-run
conformance suite for OMG's Decision Model and Notation. Each directory under
`compliance-level-2/` and `compliance-level-3/` holds one DMN model (`*.dmn`) and one or
more machine-readable expectation files (`*-test-NN.xml`) conforming to `testCases.xsd`.

- **Upstream:** `https://github.com/dmn-tck/tck`
- **Pinned commit:** see `PINNED_COMMIT`
- **Vendored:** `TestCases/compliance-level-2`, `TestCases/compliance-level-3`, `testCases.xsd`
- **Not vendored:** `non-compliant/`, the Java runners, and the per-case `.pdf`/`.png`
  documentation renderings, which are large and carry no test data.

## Licence

The TCK repository is Apache-2.0 (`LICENSE-ASL-2.0.txt`, reproduced here). The **test cases
themselves are distributed under a Creative Commons Share-Alike-With-Attribution licence**,
which the project's README states directly:

> Test cases will be files that can be accessed freely by anyone using a creative commons
> Share-Alike-With-Attribution license.

## Why it must not be edited

Share-alike attaches to derivatives. A modified test case is a derivative and would carry
the upstream licence into our own tree, so the corpus is kept byte-identical and everything
we write — the runner, the value comparator, the expected-failure list — lives **outside**
this directory.

`VENDORED_FILES.sha256` records a hash of every vendored file. `mix ash_decisions.tck.verify`
checks it and fails if anything changed, which turns "someone tweaked a test to make it pass"
from an undetectable act into a build failure.

This mirrors how `priv/cdm/schemaDocuments/` is handled in `ash_enterprise`
(see ADR 0001 and `priv/cdm/ATTRIBUTION.md`): a frozen corpus at a pinned commit, adopted
rather than depended on, never edited in place.

## Updating

Re-vendor from a new upstream commit as a single, reviewable commit that touches nothing
else: replace the two directories, update `PINNED_COMMIT`, regenerate
`VENDORED_FILES.sha256`, and re-run `mix ash_decisions.tck` so the change in the conformance
numbers is visible in the same diff.
