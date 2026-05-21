# subagentarch

Architecture documents for the opensubagents ecosystem.

```
schema/architecture.graphql   single GraphQL schema = entity-relationship
                              diagram source of truth. Every HTML doc
                              under docs/ visualizes a slice of this.
docs/01-erd-overview.html     full ERD, click-to-focus, self-contained.
                              Follows the html-effectiveness format from
                              opensubagents/subagenthtml.
```

## Where the entities come from

```
subagenttasks          Tag, Task, Subtask, ComplexityReport, +enums
                       Source: Zod schemas in subagenttasks/types/tasks.types.ts
subagentbriefs         Brief, Initiative, Link, BriefStatus
                       Source: canonical, not from any vendor
managed-agents         Agent, Session, Outcome, Environment, Tool, Skill,
                       Vault, MemoryStore, PermissionPolicy, Dream,
                       Webhook, SessionEvent, SessionFile
                       Source: platform.claude.com/docs/en/managed-agents/*
cross-cutting          FeatureFlag (subagentflags, planned),
(planned)              Trace + Span (subagentobs, planned)
```

## Reading the GraphQL schema as an ERD

- `type Foo { bar: Baz }` → Foo points at one Baz
- `type Foo { bars: [Baz!]! }` → Foo points at many Bazes
- `enum Status { ... }` → closed set of literal values
- `union X = A | B` → X is either an A or a B

No runtime, no resolvers, no server. The schema is a shape contract that the HTML documents render against. To keep them in sync: edit the schema first; if the diagram doesn't match, edit the HTML.

## Format

HTML follows the patterns at <https://github.com/opensubagents/subagenthtml> (vendored from `anthropics/html-effectiveness`):
- ivory paper background, slate text, clay accent
- serif headings, mono labels, single self-contained file
- SVG diagram with click-to-focus interactions via inline JS
- side panel that updates on selection

## Next docs to add

```
02-task-lifecycle.html         state transitions for TaskStatus
03-session-flow.html           Session → Agent → Tool/Skill/Vault flow
04-permission-policy.html      how rules and decisions interact
05-multiagent-topology.html    multi-agent sessions
06-observability-pipeline.html span path from session → CF Analytics
```

Each is one HTML file, one slice of the schema, no framework dependency.
