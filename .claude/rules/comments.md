---
paths:
  - '**/*.yml'
  - '**/*.yaml'
  - '**/*.tf'
  - 'agent/**'
---

# Comments and docblocks

- Every exported declaration has a docblock (TSDoc/JSDoc): one sentence on **what it is for**, then
  the contract a caller relies on (inputs, outputs, errors, side effects). Never paraphrase the name.
- Comments explain **why**: a constraint, a trade-off, a link to the rule or the mockup screen that
  imposes the behavior. A comment that restates the code is deleted.
- A rule taken from the mockup or the integration guide cites it: `// Mockup App.dc.html: the label
  changes on click, the row moves after 460 ms.`
- No commented-out code, no `TODO` without a task id (`TODO(WAY-512): …`).
- Keep docblocks in sync in the same change as the code they describe.
