<!-- Task spec template — https://jyoung.dev/blog/anatomy-of-a-perfect-ai-agent-task/ -->
<!-- Gate first: if the agent has no real risk of getting this wrong (typo fix, rename), skip the template and write one sentence. -->
<!-- These sections are a maximum, not a minimum. Frontier models reliably follow only ~150-200 instructions; every irrelevant detail dilutes the rest. -->
<!-- Delete all comments before handing the spec to the agent. Check the result: ./lint-task-spec.sh <this-file> -->

## Task Spec: <one-sentence description of the change>

### Goal
<!-- The outcome and why — not a step sequence. "Add phone number support to registration", not "Open user.go, find CreateUser...". -->
<!-- Name what this task delivers and what adjacent work is deliberately a separate task. -->

### Architectural Context
<!-- Only what the agent cannot infer by reading code: why the architecture is shaped this way, team conventions, tech versions, domain terms it might misinterpret. -->
<!-- If the agent could derive it from the codebase, cut it. -->

### Relevant Files
<!-- Entry points and files to touch, plus read-only references. Saves blind searching and context burn. -->
<!-- Format: `path/to/file` — role (change here | add tests here | read-only reference) -->

### Reference Implementation
<!-- Point at an existing implementation in this codebase that follows the pattern to replicate. "Do it like X" beats a paragraph of description. -->
<!-- Name the function/file to mirror and the specific properties to copy (signature shape, error handling, test layout). -->

### Constraints
<!-- Rules that must be followed: API contracts that cannot change, packages to use, dependencies not to introduce, error-handling contracts downstream code relies on. -->

### Non-Goals
<!-- Explicitly out of scope: files/layers not to touch, refactors not to do. Without this, agents refactor what you did not ask them to touch. -->

### Edge Cases
<!-- Footguns and non-obvious couplings only you know about: unique constraints, double-validation traps, inputs that must fail. -->

### Acceptance Criteria
<!-- Observable, specific, testable. Not "should work correctly". Each criterion should be checkable by running something. -->
<!-- Include an expected-change boundary if it matters, e.g. "only service.go and service_test.go change". -->

### Verification
<!-- Exact commands the agent runs to confirm its own work: test, vet/lint, and a manual probe if relevant. Indent with 4 spaces or use a code fence. -->
