# tool-contract-audit

A permissions audit tells you which tool calls an agent may make. This one checks what a permitted call means, using what an MCP server's `tools/list` shows: write tools with no idempotency key, destination parameters left as free strings, annotations that are missing or contradict the tool's name, and definitions that drift after an upgrade.

It reads definitions only. Server code, error behavior, and ownership never appear in `tools/list`, so the report prints those rows as NOT VISIBLE or UNDETERMINED. They are never counted as a pass.

## Usage

```bash
# 1. Capture tools/list from a stdio server (or bring your own JSON)
./tool-contract-audit.sh capture --out tools-list.json -- npx -y @modelcontextprotocol/server-filesystem@2025.8.21 /srv/data

# 2. Audit it
./tool-contract-audit.sh audit tools-list.json
./tool-contract-audit.sh audit --untrusted tools-list.json   # ignore readOnlyHint, audit every tool as a write

# 3. Lock definitions and the exact code pin you installed
./tool-contract-audit.sh lock tools-list.json --version @modelcontextprotocol/server-filesystem@2025.8.21

# 4. On upgrade: re-capture, then diff
./tool-contract-audit.sh diff tools-list.json --version @modelcontextprotocol/server-filesystem@2026.8.31
```

Input can be a `tools/list` JSON-RPC response, `{"tools": [...]}`, a bare array, or a JSONL capture (pages are joined). `capture` follows `nextCursor` and records the server's self-reported `serverInfo`.

| Command | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|
| `audit` | no FAIL | any FAIL | usage or input error |
| `diff` | definitions and pins unchanged | anything changed | usage or input error |
| `lock`, `capture` | ok | | error |

## What `audit` checks

A tool counts as a write unless it declares `readOnlyHint: true`. That follows MCP's defaults: readOnlyHint false, destructiveHint true, idempotentHint false, openWorldHint true.

| Check | FAIL / WARN when |
|---|---|
| `idempotency` | FAIL: a write takes no `idempotency_key`, `request_id`, `client_token`, `operation_id`, or `dedup*` parameter. WARN instead when the server claims `idempotentHint: true`, or the tool takes only a `plan_id` (the post's preview/commit shape). |
| `destination` | FAIL: a parameter whose name picks a destination (`to`, `cc`, `bcc`, `*recipient*`, `*url`, `*webhook*`, `*channel*`, `*account*`, `*owner`, `*email`, `*address`, ...) accepts a string with no `enum`, `const`, `pattern`, or `format`. Walks nested objects, arrays, and `anyOf`/`oneOf`. WARN on any `bcc` field and on unresolved `$ref`. |
| `annotations` | WARN: none declared, or `readOnlyHint: true` on a tool whose name starts with a write verb (`send_`, `delete_`, ...). The tool is audited as a write anyway. |
| `schema` | WARN: `inputSchema` has no properties and does not forbid extra ones, so it accepts anything and nothing else can be checked. |

Parameter roles are guessed from names, so treat each finding as a lead. A `pattern` or `format` PASS only means the value is well-formed. Whether `billing@northwind.com` belongs to `acct_7f3k2m9q1x0b` is a server-side check the schema cannot express.

`example-send-email.json` is the post's Bad `send_email` (2 FAIL, 1 WARN). `example-send-email-reviewed.json` applies the post's fixes: a preview/commit pair plus a keyed write (0 FAIL, 1 WARN, for the plan_id commit whose single-use you still have to confirm).

## What `lock` and `diff` do

`lock` writes `tools.lock.json`: per-tool sha256, the set hash, every definition in full, the `--version` code pin, and the self-reported `serverInfo`. The set hash matches the post's one-liner, `jq -S '.tools' tools-list.json | sha256sum`.

`diff` prints added and removed tools, a leaf-level definition diff for each changed tool, and labels taken from the post's governance list:

- **BREAKING**: field removed, required flipped either way, type changed, default changed, enum value removed.
- **WIDENING**: new destination field, constraint removed (`pattern`, `enum`, `format`, `maxLength`, ...), enum value added, `additionalProperties: false` dropped.
- **REVIEW**: tool or parameter description changed (the text the model reads), any annotation changed, a constraint value changed in a direction the script cannot judge.
- **CHANGE**: new optional field, constraint added, `outputSchema` changed.

A diff where tools only changed order is reported as unchanged.

**Implementation: always UNDETERMINED.** A definition hash cannot see server code. postmark-mcp 1.0.16 added its BCC in the send path while the definition stayed the same. When `--version` moved and the definitions did not, `diff` exits 1 and says that this is exactly the case a hash misses. The only cover for that case is an exact install pin (`npm install pkg@x.y.z --save-exact`) plus a re-run of the tool's evals before you accept the upgrade. The `serverInfo` version is self-reported by the server, so do not treat it as a pin.

## In CI

Commit `tools.lock.json` next to the tool definitions under a CODEOWNERS entry. In the PR that bumps the server, re-capture, run `diff` (exit 1 forces a look), then re-`lock` in the same PR so the lockfile and the review land together.

## Grounding

Canonical post: [Agent Tool Design Belongs in Your Harness Audit, Not Prompt Tips](https://jyoung.dev/blog/agent-tool-contracts/)

- Idempotency key on every write: duplicates fell from 28% to 4% across 25,930 LIMBO episodes, and 90% of runs that duplicated still finished as completed ([Jiapeng Li: Where Does Exactly-Once Live?](https://arxiv.org/abs/2609.29095)). The script cannot see whether a key is derived from the operation or minted per retry ([AWS: AGENTREL06-BP04](https://docs.aws.amazon.com/wellarchitected/latest/agentic-ai-lens/agentrel06-bp04.html)), and says so.
- Free-form recipient, channel, and URL parameters (P2) and servers that leave restriction to the agent (P6) ([Hao and Tan: MCP Pitfall Lab](https://arxiv.org/html/2604.21477v2)). JSON Schema cannot express programmatic checks ([MCP: SEP-1303](https://modelcontextprotocol.io/seps/1303-input-validation-errors-as-tool-execution-errors)).
- Annotation defaults and "hints" status ([MCP: schema.ts (2026-07-28)](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts)); clients treat annotations as untrusted unless the server is trusted ([MCP: Tools (2026-07-28)](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)).
- Hash-pin definitions, with OWASP's caveat that this "detects metadata changes, not changes to server code or behavior behind an unchanged definition" ([OWASP: MCP Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html)); the postmark-mcp 1.0.16 BCC ([Postmark: Security Alert](https://postmarkapp.com/blog/information-regarding-malicious-postmark-mcp-package)).
- BREAKING labels follow Azure's REST rules on enums, requiredness, and behavior changes ([Microsoft: Azure REST API Guidelines](https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md)). Treating WIDENING as a reviewed change is the post's own judgment, not a sourced rule.
