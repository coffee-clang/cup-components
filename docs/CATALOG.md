# Catalog

`catalog/catalog.cfg` is the source authority for package availability produced by
`cup-components`. The rolling GitHub Release tagged `catalog` exposes the latest published
snapshot to cup through a stable `catalog.cfg` asset URL.

The two copies have different roles:

```text
repository catalog/catalog.cfg
        │
        │ source authority
        ▼
rolling Release "catalog"
        │
        │ consumer delivery
        ▼
       cup
```

Publication always moves in that direction. The release is never used to reconstruct or
silently rewrite the repository source catalog.

See [Specification](SPECIFICATION.md#catalog) for the catalog fields, package identity,
version comparator and canonical ordering.

## What the catalog represents

A catalog record describes one package identity that has already been published and
verified. It contains the concrete component, tool, host, target and package version,
together with the three downloadable archive URLs and their SHA-256 digests.

`stable=true` is stored for direct consumption but is not independent policy. For each
`(component, tool, host, target)` scope it must identify the semantic maximum package
version. Activating a newer package therefore moves `stable` automatically; activating an
older historical package does not.

The catalog deliberately does not contain package-build policy, source-selection policy,
cup defaults or package manifest digests. Those values have different owners.

## Activation

`scripts/catalog/catalog.sh activate` takes a canonical package release tag and updates a
catalog snapshot only after proving that release.

The activation path:

1. reads and validates the package release `publication.txt`;
2. checks that the structured identity derives the supplied canonical release tag;
3. checks the exact managed release-asset names and their GitHub-reported SHA-256 digests;
4. derives the three canonical archive URLs;
5. adds the package when the identity is absent;
6. treats identical already-recorded data as an idempotent no-op;
7. rejects the same package identity with different immutable data;
8. recomputes `stable` and canonical ordering;
9. advances catalog `revision` only when the resulting snapshot changes.

Archive bytes do not need to be downloaded again during activation. Their exact digests
are already bound by the immutable package release and `publication.txt`; the catalog
publisher verifies those remote asset digests rather than repeating native/package
qualification work.

Catalog `revision` identifies a source snapshot generation, not the number of package
operations. A normal one-package activation usually advances it by one, while a deliberate
administrative edit can change several records under one next revision.

## Normal automatic publication

Normal package visibility is automatic after a producer has successfully published and
verified its immutable package release:

```text
package build + native qualification
        ↓
immutable package release
        ↓
dispatch Update Catalog
        ↓
serialized catalog writer
        ↓
activate against latest source catalog
        ↓
commit/push catalog/catalog.cfg
        ↓
synchronize rolling Release "catalog"
```

Builds for different package identities remain parallel. Published runs for the same
identity are serialized before their immutable release boundary, while catalog
mutation/publication uses the shared `cup-components-catalog` concurrency group because
the source catalog and rolling release are single-writer resources.

Every catalog update starts from the current default-branch authority. If a repository
push races with another branch update, the writer retries from the new branch state and
re-applies the idempotent activation. Retries are bounded; the workflow never force-pushes
or overwrites a newer source snapshot.

The producer workflows use the repository `GITHUB_TOKEN`: `contents: write` publishes the
package release, while `actions: write` dispatches `Update Catalog`. The catalog writer
uses `contents: write` for the controlled source commit and rolling release. No separate
bot account, PAT or GitHub App is part of this lifecycle. Repository branch rules must
allow that workflow-owned catalog commit; otherwise the package remains published and the
catalog update fails safely for later retry.

The repository update is committed before the rolling release is synchronized. Therefore
a publication failure can leave:

```text
repository catalog = revision N+1
public catalog     = revision N
```

which is safe and recoverable. The inverse state is not intentionally produced: public
availability must not advance ahead of its source authority.

If package publication succeeds but catalog activation/publication fails, the package
release remains valid and immutable. It is simply not discoverable through cup until the
catalog update is retried successfully.

## Rolling release update

`scripts/publish/publish-catalog.sh sync` compares the source candidate with the currently
published `catalog.cfg` before changing the rolling release:

- lower candidate revision: reject rollback;
- same revision and identical bytes: idempotent success;
- same revision and different bytes: reject inconsistent history;
- higher revision: validate the transition and publish the new snapshot.

GitHub does not replace a same-name release asset atomically. The publisher therefore uses
one transient managed asset, `catalog.cfg.next`:

```text
upload catalog.cfg.next
        ↓
verify exact digest
        ↓
delete old catalog.cfg
        ↓
rename verified next -> catalog.cfg
        ↓
verify final asset
```

If both `catalog.cfg` and a stale `catalog.cfg.next` are present after an interrupted run,
the canonical `catalog.cfg` is still the last committed public snapshot and the transient
asset can be discarded. If the canonical asset is missing but a verified `catalog.cfg.next`
remains, the publisher completes that interrupted rename before considering a newer source
snapshot.

A short external gap between deleting the old canonical asset and renaming the verified
candidate is accepted. cup keeps its existing local catalog when a remote refresh cannot
be downloaded or validated, so `cup-components` does not add a second catalog pointer or
versioned catalog-release history solely to hide that external limitation.

## Initial bootstrap and administrative recovery

The normal package pipeline assumes that the rolling `catalog` release already exists.
The automatic writer checks that precondition before changing source authority; if the
endpoint was never bootstrapped, the package release remains valid and the catalog update
fails without committing revision 1 first. The first endpoint is therefore created once
from the tracked empty revision-0 catalog:

```text
format=1
revision=0
update_url=https://github.com/coffee-clang/cup-components/releases/download/catalog/catalog.cfg
```

The manual `Publish Catalog` workflow exposes `bootstrap` for that one-time creation and
`sync` for explicit recovery/administrative publication. It shares the same concurrency
group as automatic updates so manual recovery cannot mutate the rolling asset concurrently
with a normal package activation.

Manual publication is not a normal visibility gate. New qualified packages become visible
through the automatic path above.

A rare security/legal/administrative de-advertisement can deliberately edit the repository
source catalog, increment its revision, validate/commit the new snapshot and use the manual
sync path. Removing a catalog record does not delete the immutable package release; hard
removal of historical bytes is a separate exceptional administrative action.

## Boundary with cup

`cup-components` owns catalog production and publication. cup consumes the published
snapshot, chooses packages from it and manages the user's local catalog state. cup does
not decide producer `stable`, reconstruct archive URLs or infer package availability from
GitHub releases on its own.
