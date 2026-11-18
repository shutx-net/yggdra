# yggdra — Concept and Technical Design

> **Status:** Design only; nothing is implemented yet. Decisions below are settled for the MVP unless listed as open in §12.  
> **Name:** `yggdra` (project and CLI)  
> **Initial target:** Structural analysis and interactive exploration of Go projects, on Linux  
> **Technologies:** Odin, raylib, Dear ImGui, Go  
> **Guiding principles:** Web-independent, local-first, static analysis, SSOT, analyzers as separate processes

## 1. Background and Goals

As AI coding agents take on an increasing share of the implementation work in large software products, it becomes harder for humans to understand the overall code structure, dependencies, and impact of changes.

Conventional file trees, code search, and flat dependency graphs make it difficult to combine a high-level overview with detailed exploration. This project aims to build **a native tool that extracts structure from source code and presents it in an interactive spatial view, allowing humans to explore, understand, and audit software systems**.

### Intended Value

- Explore a project at multiple levels of granularity: packages, types, functions, and calls.
- Select a node to follow incoming and outgoing dependencies and the source evidence behind them.
- Help humans understand and review the structure of implementations created or modified by AI coding agents.
- Eventually support commit-to-commit comparisons, architecture constraint checks, and analysis in CI.
- Keep both analysis and exploration local, without requiring a web service or browser.

Auditing a change means comparing the snapshots of two commits. Comparison itself is a later phase, but it only works if node identities are stable and output is deterministic, so both are MVP requirements (§6).

### Source of Truth (SSOT)

**Source code and related definition files are the single source of truth.** The generated graph is derived data that can be regenerated. Every relationship shown in the viewer keeps a link to the source location that supports it.

## 2. MVP Scope and Non-Goals

### MVP Scope

1. Analyze one Go module under one build configuration.
2. Extract packages, import dependencies, and declarations of types, functions, and methods.
3. Extract calls that the type checker resolves, and record calls it cannot resolve without guessing their targets.
4. Emit the result as a deterministic snapshot in the common graph format.
5. Render the graph in a native Odin viewer with camera controls.
6. Support node selection, search, dependency highlighting, and source-location inspection.
7. Save snapshots and reopen them later.

### Not in the MVP

**Analysis**

- Other languages and formats (OpenAPI, Terraform, CloudFormation, Kubernetes, ...).
- SSA and call-graph algorithms (CHA/RTA/VTA), candidate callees for interface calls, and `implements` or `references` edges.
- Test files (`_test.go`), several build configurations in one snapshot, and multi-module workspaces.
- Incremental analysis, file watching, caches, and databases.
- Runtime traces.

**Integration**

- A generic plugin SDK, plugin discovery or registration, bidirectional RPC, and binary protocols.

**Viewer**

- Force-directed layout, animation, and visual polish.
- An in-app source viewer and editor integration (a path and line number are enough).
- Windows and macOS builds.
- A renderer abstraction layer (confining raylib imports to two packages is enough, see §3).

**Product**

- SaaS, cloud synchronization, or anything that requires a browser or web server.
- Snapshot diffs, CI checks, and architecture rules (Phase 5; the contract is prepared for them).

## 3. High-Level Architecture

```text
       Go source repository (SSOT)
                  |
                  v
             Go Analyzer
       (standalone Go process)
        go/packages + go/types
                  |
                  | stdout: JSON Lines, one-way
                  | (same format as a saved snapshot)
                  v
      +-----------------------------+
      |     Odin Core (headless)    |
      |                             |
      |  plugin    process control  |
      |  snapshot  read / write     |
      |  graph     validate, index, |
      |            query, aggregate |
      |  layout    deterministic    |
      |            placement        |
      +--------------+--------------+
                     |
                     v
      +-----------------------------+
      |     Native Desktop Viewer   |
      |                             |
      |  renderer  raylib: 3D,      |
      |            camera, picking  |
      |  ui        Dear ImGui:      |
      |            panels, search   |
      +--------------+--------------+
                     |
                     v
            OS + GPU / driver
```

| Component | Responsibility | Implementation |
| --- | --- | --- |
| Go Analyzer | Go-specific loading, type checking, and extraction | Go |
| Graph contract | Language-independent nodes, edges, and evidence | Versioned JSON Lines records (§6) |
| `plugin` | Start the analyzer, enforce limits, collect its output | Odin (`core:os` process API) |
| `snapshot` | Read and write the record stream | Odin |
| `graph` | Validation, indexes, queries, aggregation for collapsed groups | Odin |
| `layout` | Deterministic placement from graph and view state | Odin |
| `renderer` | Drawing, camera navigation, hit testing | Odin + raylib |
| `ui` | Project tree, search, detail panels, display controls | Odin + Dear ImGui |

**Dependency rule:** `plugin`, `snapshot`, `graph`, and `layout` are headless and must not import raylib or ImGui. Only `renderer` and `ui` may. This keeps the headless packages testable without a display and makes the rendering layer replaceable.

### Why Odin for the Core?

- Learning and using Odin is part of the motivation for this project.
- It gives direct control over native rendering and memory.
- Its data-oriented style fits graph storage, array processing, and camera math.
- It needs no browser, Electron, or Node.js runtime.

Known costs: Odin has no stable 1.0 release and no package manager, and its Dear ImGui bindings are third-party (§8). They are contained by pinning the toolchain (§11) and by the process boundary: the Go analyzer and the graph contract do not depend on the viewer's language, so a failed viewer experiment costs only the viewer.

**Language-specific analysis stays out of Odin.** Go's own loader and type checker are the practical way to analyze Go.

## 4. Runtime and CLI

The Odin core is a native executable. The Go analyzer is a second executable, started by the core as a child process. No JVM, Node.js, browser, or HTTP server is involved.

The MVP targets Linux only. NixOS with KDE Plasma is the first test environment, under both Wayland and X11. Other platforms are not built or tested, but the headless packages should not take Linux-only shortcuts where a portable call costs the same.

### Proposed CLI (not implemented)

```bash
# Analyze a module and open the viewer
yggdra open ./my-go-project

# Analyze and save only
yggdra scan ./my-go-project --output graph.jsonl

# Inspect an existing snapshot offline
yggdra view graph.jsonl
```

The core locates the Go analyzer next to its own executable or through an explicit flag. It does not search `PATH` or configuration directories.

## 5. Analyzer Integration

### Principles

- Analyzers run **out of process**. They are never loaded into the Odin process as shared libraries.
- Each analyzer is written in whatever language has the best tooling for its target.
- Analyzers describe **meaning**. They never emit colors, coordinates, or other presentation data.
- Language differences are reconciled through the common graph contract.
- Analyzer output is untrusted input: the core validates all of it (§6).

### Protocol v0

The analyzer is a one-shot command. There is no handshake and no request channel.

```text
Odin Core                                Go Analyzer
    |                                        |
    +-- start: <analyzer> [flags] <dir> ---->|
    |<------- stdout: header ----------------+
    |<------- stdout: node, edge, ... -------+
    |<------- stdout: diagnostic ... --------+
    |<------- stdout: complete --------------+
    |<------- exit code 0 -------------------+
```

- **stdout** carries protocol records only, one JSON object per line.
- **stderr** carries human-readable logs only.
- **stdin** is not used.
- The stream starts with one `header` and ends with one `complete`. A stream without `complete` is truncated and is rejected.
- A saved snapshot is this same record stream. There is one format, not an IPC format and a file format.

Because the analyzer needs nothing but arguments, it can be run and tested by hand without the core.

### Host Responsibilities

- Enforce a timeout and kill the analyzer when it expires.
- Read stdout and stderr concurrently, so that a full pipe cannot block the analyzer.
- Never block the UI thread on analysis.
- Enforce the input limits of the contract ([contract.md](contract.md#limits)).
- Treat a non-zero exit code, a timeout, or a truncated stream as a failed analysis. A failed analysis produces no snapshot.

### Security

Analysis targets may contain proprietary source code and may themselves be untrusted.

- Only the bundled analyzer is started. There is no mechanism for running third-party analyzers.
- The analyzer must not reach the network or execute code from the analyzed repository. The Go-specific defaults that enforce this are in §7.

> A separate process gives fault isolation; it is **not** an operating-system sandbox. Filesystem and network confinement would need additional controls.

## 6. Graph Contract

The analyzer's output and saved snapshots share one versioned format, specified in [contract.md](contract.md). Its main decisions:

- Records are JSON Lines: one `header`, the `node` records, the `edge` records, the `diagnostic` records, and one `complete` whose counts expose truncation.
- Nodes form one containment tree: package → type, interface, or function; type or interface → method. Files are not nodes; declarations carry their file and position.
- Edges are `imports` and `calls`. One edge merges every occurrence of a relationship and lists each one as a site, so every relationship keeps its evidence.
- Every edge has a certainty: `established` (proven by the type checker) or `unresolved` (the relationship exists, but its target cannot be named). `inferred` is reserved for approximations. There are no numeric confidence scores.
- Node IDs stay the same across commits as long as a declaration keeps its package, receiver, and name.
- Output is deterministic and machine-independent: sorted records, no timestamps, no absolute paths.
- The core validates every record strictly, including unknown and duplicate keys, and rejects an invalid stream with the offending line. A snapshot with error diagnostics is valid, but the viewer shows it as incomplete.

### Core Responsibilities

1. Validate records and build indexes.
2. Query incoming and outgoing dependencies and n-hop neighborhoods.
3. Collapse and expand along the containment tree, deriving aggregated edges.
4. Keep evidence reachable from every displayed relationship, including aggregates.
5. Save and load snapshots.

## 7. Go Analyzer

### Technologies

| Go Package / API | Use |
| --- | --- |
| `golang.org/x/tools/go/packages` | Loading the module's packages under one build configuration |
| `go/types` | Resolving identifiers, callees, and method receivers |
| `go/ast` / `go/token` | Traversing syntax and reporting positions |

`go/ssa` and `go/callgraph` are not used in the MVP.

### Loading Rules

- Load the module that contains the given directory, with the pattern `./...`.
- Use one build configuration per run: the host's `GOOS` and `GOARCH` and no extra build tags, unless flags say otherwise. The effective configuration is recorded in the header.
- Exclude test files.
- Run the `go` command with `GOPROXY=off`, `GOTOOLCHAIN=local`, and `CGO_ENABLED=0`. Only an explicit flag relaxes them, and the header records whether downloads and cgo were allowed ([contract.md](contract.md#root-and-context)).
  - `GOPROXY=off`: a dependency missing from the local module cache becomes a diagnostic, not a download.
  - `GOTOOLCHAIN=local`: a `go.mod` that asks for another toolchain becomes a diagnostic, not a toolchain download.
  - `CGO_ENABLED=0`: cgo and the C compiler are never invoked. Files that import `"C"` are excluded from the graph.
- Type-check from source rather than from compiled export data, so that loading does not build dependencies. The exact `go/packages` mode is confirmed during implementation.
- Load and type errors become `diagnostic` records with root-relative positions. The analyzer still emits everything it could establish.

### Boundary of the Graph

External code (the standard library and dependencies) is represented only as far as the analyzed module refers to it: external packages as import targets, and external functions, methods, and their containing types as call targets. **No edge starts at an external node**, and external declarations that nothing refers to are not emitted.

### How Go Constructs Are Recorded

| Source construct | Recorded as |
| --- | --- |
| Package import | `imports`, `established` |
| Call to a declared function or a concrete method | `calls`, `established`, target is the declaration |
| Call to an interface method | `calls`, `established`, target is the interface's method node; the implementation that runs is not identified |
| Call through a function value (variable, field, parameter, returned function) | `calls`, `unresolved`, no target |
| Call in a package-level initializer | Same as above, with the package as source |
| Direct call of a function literal | Not an edge; the literal's body belongs to the enclosing declaration |
| Conversions such as `T(x)` and built-ins such as `len` | Not calls; not recorded |
| Reflection, dynamic registration, `go:linkname`, assembly | Not detected; not represented |

**Design rule:** Never confuse a relationship that **may exist** with one that was **established**. The viewer presents interface methods as abstract targets and unresolved calls as unresolved.

## 8. Viewer

### Screen Layout

```text
+----------------------------------------------------------+
| yggdra                      [Search]  [Filters] [View]   |
+----------------+---------------------------+-------------+
| Project Tree   |                           | Details     |
|                |        Graph View         |             |
| Packages       |                           | Node info   |
| Types          |   orbit / pan / zoom      | Edges       |
| Functions      |   select / highlight      | Certainty   |
|                |                           | Sites       |
+----------------+---------------------------+-------------+
| status: analysis / diagnostics / node count / selection  |
+----------------------------------------------------------+
```

### Essential Interactions

- Orbit, pan, and zoom the camera.
- Select nodes and inspect their details.
- Highlight incoming and outgoing dependencies in distinct colors.
- Expand and collapse along the containment tree.
- Search by name and move the camera to a match.
- Show the file path and line of every node and edge site.

### Level of Detail

Showing every node at once does not help anyone understand a large codebase. The view starts collapsed and reveals detail on demand:

1. **Overview:** packages, grouped by directory, with import edges and aggregated call edges.
2. **Intermediate:** the types and functions of an expanded package.
3. **Detail:** the methods, calls, and sites of a selected declaration.

### Layout

- Layout is a deterministic function of the graph and the view state (which groups are expanded). It uses no randomness and does not depend on input order.
- The first layout follows the containment tree: nested regions on a plane, children inside their parent's region.
- Force-directed layout is excluded. It gives a different picture on every run, which destroys the reader's mental map and contradicts deterministic output.
- Positions and styling are never written to a snapshot.

### 3D Is a Hypothesis

3D node-link views suffer from occlusion and perspective distortion, and may be harder to read than 2D. The layout produces 3D coordinates, and a flat layout is the case where one axis is unused, so both run through the same code. Phase 1 compares a top-down 2D view with a 3D view on the same real data. If the third axis is kept, it carries exactly one meaning, chosen in that comparison. The goal is accurate, understandable exploration, not 3D for its own sake.

### Rendering and UI Libraries

Facts checked in November 2026 against Odin `dev-2026-11`:

- `vendor:raylib` binds raylib 6.2 and includes `rlgl` and `raygui`. The upstream distribution bundles prebuilt raylib libraries, but nixpkgs' Odin deletes them and links the system raylib instead. The dev shell therefore links nixpkgs' raylib 6.2, built on nixpkgs' GLFW 3.4 ([development.md](development.md)).
- Dear ImGui is not in `vendor`. The third-party `odin-imgui` bindings cover GLFW, SDL2, SDL3, OpenGL 3, and other backends, but **not raylib**, and building them needs clang and Python.
- `vendor:microui` and `raygui` exist, but do not cover the trees, tables, and text input this UI needs.

So raylib with ImGui requires a custom or community `rlgl` backend, and that integration is the first thing Phase 1 validates. If it proves fragile, the fallback is to keep ImGui and replace raylib with SDL3 or GLFW plus OpenGL, where ImGui backends already exist. The viewer's 3D needs are small: instanced shapes, lines, and text.

## 9. Implementation Sequence

### Phase 0 — Contract and Real Data

- Write the v0 contract document ([contract.md](contract.md)). Done.
- Build a thin Go analyzer that emits packages and `imports` edges only, deterministically.
- Add a small Go module as a fixture, with a golden snapshot, plus valid and invalid snapshot samples.
- Generate snapshots of one or two real, mid-sized open-source Go projects for viewer evaluation. They are generated locally and not committed.
- Pin the toolchains (§11).

**Completion criterion:** The analyzer reproduces the golden snapshot byte for byte, and a snapshot of a real project exists.

Real data comes first because layout decisions made on a hand-written toy graph do not survive contact with a real one.

### Phase 1 — Risk Spikes (time-boxed)

- raylib + Dear ImGui in Odin on NixOS/KDE, under Wayland and X11: a window, a 3D scene, and one panel with a tree and a text input.
- Load a real snapshot, apply the containment layout, and compare 2D with 3D.

**Completion criterion:** Two decisions are recorded in this document: whether raylib stays, and whether the third axis stays and what it means.

### Phase 2 — Core and Viewer on the Package Graph

- Headless packages: snapshot reader and validator, graph indexes and queries, layout. Tested without a display.
- Viewer: camera, picking, selection, search, highlighting, detail panel with sites.
- Analyzer process management: start, concurrent pipe reading, timeout, exit code.
- `open`, `scan`, and `view`.

**Completion criterion:** `yggdra open <dir>` shows the package import graph of a real repository.

### Phase 3 — Declarations and Calls

- Extend the Go analyzer to types, interfaces, functions, methods, and `calls` edges with certainty.
- Emit diagnostics for load and type errors.
- Expand and collapse in the viewer, with aggregated edges derived in the core.

**Completion criterion:** The MVP Definition of Done (§13).

### Phase 4 — Validation on Real Projects

- Measure layout, rendering (nodes, edge lines, labels), picking, and search on graphs of thousands of nodes or more. Optimize only what the measurements show.
- Check extracted relationships against the source of real projects.
- Promote the contract to `schema_version` 1 once compatibility is needed.

### Phase 5 — Future Extensions

- Structural differences between two commits.
- Headless analysis in CI.
- Machine-checkable architecture rules, such as layer boundaries and cycle detection.
- `implements` edges and `inferred` candidate callees.
- Analyzers for other languages; OpenAPI, IaC, and runtime traces.

## 10. Proposed Repository Layout

Only `docs/` and the Nix flake exist so far.

```text
yggdra/
├── core/                     # Odin
│   ├── graph/                # Model, validation, indexes, queries   (headless)
│   ├── snapshot/             # JSON Lines read/write                 (headless)
│   ├── plugin/               # Analyzer process management           (headless)
│   ├── layout/               # Deterministic placement               (headless)
│   ├── renderer/             # raylib
│   └── ui/                   # Dear ImGui
├── plugins/
│   └── go-analyzer/          # Go analyzer
├── fixtures/                 # Sample Go module, golden and invalid snapshots
├── docs/
├── flake.nix                 # Pinned development environment
└── README.md
```

Tests live next to the code they test.

## 11. Toolchain and Testing

- **Pin everything.** The Nix flake pins the toolchain: Go's minor version in `flake.nix`, and Odin, raylib, and the other tools through the nixpkgs revision in `flake.lock` ([development.md](development.md)). Odin releases are monthly and may break source compatibility, so a lock update is a deliberate change. `go.mod` states the same Go version. Odin has no package manager, so third-party Odin libraries are vendored copies at a recorded commit.
- **The fixtures are the conformance suite.** The Go analyzer must reproduce the golden snapshots byte for byte. The Odin validator must accept every valid sample and reject every invalid one. Both sides are tested against the same files, which is what keeps producer and consumer from drifting.
- **No JSON Schema file for now.** Nothing in the toolchain would validate against it, so it would drift from the code. The contract is prose plus fixtures until a tool consumes a schema.
- **GUI verification is isolated.** Everything outside `renderer` and `ui` is tested offline and without a display.

## 12. Open Questions and Risks

| # | Question | Resolved in |
| --- | --- | --- |
| 1 | Does raylib + Dear ImGui work reliably in Odin on NixOS, under Wayland and X11, with nixpkgs' raylib and GLFW? | Phase 1 |
| 2 | Does 3D help or hurt compared with 2D, and what should the third axis mean? | Phase 1 |
| 3 | Does the containment layout stay readable as node counts grow? | Phases 1 and 4 |
| 4 | Does `scan` need its own executable without raylib, for machines with no graphics libraries? | When CI use becomes real |
| 5 | Does the ID scheme hold on real code (vendoring, generics, embedding, several `init` functions)? | Phases 0 and 3 |
| 6 | How should test files, several build configurations, and multi-module workspaces enter the model? | After the MVP |
| 7 | When are `implements` edges and `inferred` candidates worth their noise? | Phase 5 |
| 8 | Is process isolation enough for the analyzer, or is OS-level confinement needed? | After the MVP |

**Reconsideration trigger:** If Phase 1 shows that UI work, rendering, or NixOS compatibility is significantly harder than expected, replace the rendering layer first (§8). The analyzer and the contract are unaffected.

## 13. MVP Definition of Done

- [ ] The native Odin viewer launches locally on Linux.
- [ ] The Go analyzer runs as a separate process, with no network access and no cgo by default.
- [ ] Packages, imports, declarations, and calls are extracted from a real Go module.
- [ ] Analyzing the same input twice yields byte-identical snapshots.
- [ ] The core rejects invalid snapshots and names the offending line.
- [ ] A saved snapshot can be loaded and explored, with camera controls and node selection.
- [ ] Incoming and outgoing dependencies and their source sites can be inspected for a selected node.
- [ ] Interface calls and unresolved calls are visibly distinct from calls to concrete declarations.
- [ ] A snapshot with error diagnostics is shown as incomplete.
- [ ] `scan` and `view` can be used independently.
- [ ] Viewing a snapshot needs no internet connection or browser.

## 14. Design Principles

1. **Source First:** Source code is authoritative; the graph is derived data.
2. **Evidence First:** Every displayed relationship keeps its source sites.
3. **Local First:** No web or cloud dependency.
4. **Language-Agnostic Core:** Language-specific analysis lives in analyzers.
5. **Renderer Independence:** No coordinates or styling in the graph model.
6. **Deterministic Output:** Same input, same bytes; stable identities.
7. **Progressive Disclosure:** Reveal detail through exploration, not all at once.
8. **Small Core, Real Analyzer:** A working Go analyzer before any general framework.
9. **No False Certainty:** Established, inferred, and unresolved are never mixed.

---

**Next concrete step:** Phase 0 — build the thin Go analyzer that emits the package import graph, with its fixture module and golden snapshot.
