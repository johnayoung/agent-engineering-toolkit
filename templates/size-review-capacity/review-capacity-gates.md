# Review-capacity gates

Run top to bottom before scaling the agent fleet. Each unchecked box is where the review pipeline breaks before the agents do. From [Review Capacity Is the Real Ceiling on Your Agents](https://jyoung.dev/blog/review-capacity-agent-throughput/). Copy into a PR template, an agent-rollout proposal, or a quarterly process review.

- [ ] **1. Measuring reviewer-hours, not agent output quality.**
  Violation signal: review time climbing while you keep optimizing the agent.
- [ ] **2. Did the reviewer-hours math before the last agent was added.** (`size-review-capacity.sh` computes it.)
  Violation signal: queue depth up, shippable throughput flat.
- [ ] **3. Review agents measured by load removed, not comments posted.**
  Violation signal: comment volume up, accepted-comment ratio down.
- [ ] **4. Review depth triaged by risk class before a human looks.**
  Violation signal: same rigor on a config change and a payments path.
- [ ] **5. Per-reviewer cap on high-risk AI diffs, named and enforced.**
  Violation signal: senior engineers quietly absorbing overflow; attrition risk invisible on dashboards.
- [ ] **6. Delegable inspection split from non-delegable judgment.**
  Violation signal: nobody named as the human who owns each high-risk merge.
