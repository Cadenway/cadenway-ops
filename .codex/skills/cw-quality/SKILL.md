---
name: cw-quality
description: Run the static checks, stopping at the first failure.
---

Run the [full local gate](../../../docs/development.md#full-local-quality-gate) from this checkout. Follow its order and
stop at the first failure. Report passed, failed, not run or unavailable for each check and
explain gaps. For targeted work, use the [minimum checks](../../../AGENTS.md#commands-and-quality-gates).
Use only the local example inputs listed in the gate. Compose validation does not start the stack.
