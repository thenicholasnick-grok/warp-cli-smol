# Branch policy

Bots push `feature/*` branches with a repo deploy key and open a PR. `main` changes only through a PR approved by the owner. A `main` ruleset with no bypass blocks direct pushes, force-pushes, and deletes, including from deploy keys.
