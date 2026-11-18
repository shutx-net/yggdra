# Architecture Explorer — Concept and Technical Design Draft

> **Status:** Concept / early design (not yet implemented)  
> **Working name:** Architecture Explorer / `archview` (not finalized)  
> **Initial target:** Structural analysis and interactive 3D exploration of Go projects  
> **Primary technologies:** Odin, raylib, Go  
> **Guiding principles:** Web-independent, local-first, static analysis, SSOT, extensible analyzer plugins

## 1. Background and Goals

As AI coding agents take on an increasing share of the implementation work in large software products, it becomes harder for humans to understand the overall code structure, dependencies, and impact of changes.

Conventional file trees, code search, and 2D dependency graphs make it difficult to combine a high-level overview with detailed exploration. This project aims to build **a native tool that extracts structure from source code and presents it in an interactive 3D space (with 2D/2.5D views where appropriate), allowing humans to explore, understand, and audit software systems**.

### Intended Value

- Explore a project at multiple levels of granularity, including packages, types, functions, and calls.
- Select a node to follow incoming and outgoing dependencies, references, and the underlying source evidence.
- Help humans understand and review the structure of implementations created or modified by AI coding agents.
- Eventually support commit-to-commit comparisons, architecture constraint checks, and continuous analysis in CI/CD.
- Keep both analysis and exploration local, without requiring a particular web service or browser.

### Source of Truth (SSOT)

**Source code and related definition files are the single source of truth.** The generated graph is not authoritative: it is derived data or an analysis snapshot that can be regenerated. Relationships shown in the viewer should retain links to their source definitions wherever possible.

## 2. Initial Scope and Non-Goals

### MVP Scope

1. Select a Go project for analysis.
2. Extract packages, import dependencies, and definitions of types, functions, and methods.
3. Extract direct function calls where feasible.
4. Convert the results to a common graph model.
5. Render the graph in a native Odin GUI with 3D orbit, pan, and zoom controls.
6. Support node selection, search, dependency highlighting, and source-location inspection.
7. Save analysis results and reopen them later.

### Out of Scope Initially

- Analysis of OpenAPI, Terraform, CloudFormation, Kubernetes, and similar formats (possible future plugins).
- Uniform, high-precision analysis of every programming language.
- Definitive reconstruction of all runtime execution paths, including dynamic dispatch and reflection.
- Advanced database/ORM analysis and runtime-trace integration.
- SaaS, cloud synchronization, or an architecture that requires a browser or web server.
- Designing a complete, generic Plugin SDK before a working analyzer exists.

## 3. High-Level Architecture

```text
       Go source repository (SSOT)
                  |
                  v
          Go Analyzer Plugin
       (standalone Go process)
          AST / types / packages
                  |
                  | Local IPC (initial proposal:
                  | stdio + JSON Lines)
                  v
      +-----------------------------+
      |          Odin Core          |
      |                             |
      |  Plugin Host                |
      |  Graph Model / Index        |
      |  Query / Filter / Layout    |
      |  Snapshot I/O               |
      |                             |
      +--------------+--------------+
                     |
                     v
      +-----------------------------+
      |     Native Desktop Viewer   |
      |                             |
      |  raylib: window / 3D        |
      |  ImGui: panels / controls    |
      |  picking / camera / LOD     |
      +--------------+--------------+
                     |
                     v
            OS + GPU / driver
          Linux / Windows / macOS
```

**Separation of responsibilities:**

| Component | Responsibility | Proposed Implementation |
| --- | --- | --- |
| Odin Core | Plugin lifecycle, graph storage/integration/search, snapshots, layout orchestration | Odin |
| Go Analyzer | Go-specific syntax, type, and dependency analysis | Go |
| Graph Model | Language-independent nodes, edges, and provenance | Versioned JSON schema |
| 3D Renderer | Graph rendering, camera navigation, hit testing | Odin + raylib |
| Desktop UI | Project tree, search, detail panels, display controls | Dear ImGui (integration to be validated in a PoC) |
| Layout | Hierarchical placement, clustering, overlap reduction | Start with a simple custom approach; evaluate Graphviz or others later |

### Why Odin for the Core?

- Learning and using Odin is itself part of the motivation for this project.
- It provides fine-grained control over native rendering and memory management.
- Its data-oriented design fits graph representations, array processing, cameras, and matrix operations.
- It does not require a browser, Electron, or a Node.js runtime.

However, **language-specific analysis should not be forced into Odin**. Go already provides mature AST and type-analysis facilities, so implementing the Go analyzer in Go is more practical.

## 4. Runtime and User Experience

Build the Odin Core as a **native executable** that runs directly on the operating system. raylib handles window creation and GPU rendering; Dear ImGui or an equivalent library provides search and detail panels. A JVM, Node.js, web browser, and HTTP server are not required.

- **Linux:** Runs as an ELF executable with the necessary shared libraries and graphics drivers.
- **Windows:** Runs as an `.exe`.
- **macOS:** A possible future target; build tooling and graphics backends need validation.
- **NixOS / KDE Plasma:** A strong candidate for the initial test environment. Consider Flakes for build and dependency management, and verify Wayland/X11 compatibility.

Initially, the Odin native executable and the Go analyzer plugin are **separate processes / separate executables**. Even without a language-level runtime, OS, GPU, and library dependencies remain.

### Proposed CLI (Tentative)

```bash
# Analyze a project and open the GUI
archview open ./my-go-project

# Analyze and save only (CI or batch use)
archview scan ./my-go-project --output graph.json

# Inspect an existing snapshot offline
archview view graph.json
```

Users should eventually be able to open a repository either from the GUI or by supplying a CLI path. Both the `archview` name and the command syntax are placeholders.

## 5. Plugin Architecture

### Design Principles

- Use **out-of-process plugins**. Do not initially load analyzers as shared libraries into the Odin process.
- Implement the Go plugin in Go; future TypeScript, Java, Python, and other plugins can use the most suitable tooling for their language.
- Plugins describe the **meaning** of the extracted structure. They should not prescribe colors, 3D coordinates, or other presentation details.
- Reconcile language-specific differences through a **common graph schema**, rather than forcing all analyzers into a single implementation language.
- Isolate plugin crashes and hangs from the host, and handle timeouts, exit codes, and standard error.

### Initial Protocol

The initial proposal is **standard input/output + JSON Lines (JSONL)**. Candidate message types include `hello`, `analyze`, `node`, `edge`, `diagnostic`, and `complete`.

```text
Odin Core                     Go Analyzer
    |                             |
    +-- start process ----------->|
    +-- analyze(project) -------->|
    |<-------- nodes / edges -----+
    |<-------- diagnostics -------+
    |<-------- complete ----------+
    +-- build/render graph        |
```

JSON Lines makes streaming large results and debugging straightforward. If very large outputs later create performance problems, evaluate a binary format or incremental/delta transfer. Avoid overengineering the protocol in the first iteration.

### Security Considerations

Analysis targets may contain commercial or proprietary source code. **Do not execute arbitrary, untrusted plugins without controls.** Launch only approved plugins and constrain working directories, inputs, and execution time. Go package loading can be affected by build environment settings and external dependency resolution, so requirements for an offline analysis mode should be investigated.

> Running a plugin in a separate process improves fault isolation; it is **not** an operating-system sandbox. Network and filesystem restrictions require additional controls.

## 6. Common Graph Model

Before building a sophisticated rendering engine, define the data contract for **what the graph represents and what evidence supports each relationship**.

### Minimum Elements

- **Node:** Package, file, type, function, method, etc.
- **Edge:** Relations such as `imports`, `declares`, `calls`, and `references`.
- **Source Location:** File, line/column, and optionally the full definition range.
- **Evidence / Confidence:** Distinguish directly established relationships from conservative estimates or candidate relationships.
- **Analysis Context:** Language, analyzer version, repository commit, Go build tags, GOOS/GOARCH, etc.

Illustrative data example (not a finalized schema):

```json
{
  "schema_version": 1,
  "analysis": {
    "language": "go",
    "revision": "<git-commit-sha>",
    "goos": "linux",
    "goarch": "amd64"
  },
  "nodes": [
    {
      "id": "go:example.com/app/handler:GetUser",
      "kind": "function",
      "name": "GetUser",
      "source": { "file": "handler/user.go", "line": 42 }
    },
    {
      "id": "go:example.com/app/service:FindUser",
      "kind": "function",
      "name": "FindUser",
      "source": { "file": "service/user.go", "line": 18 }
    }
  ],
  "edges": [
    {
      "source": "go:example.com/app/handler:GetUser",
      "target": "go:example.com/app/service:FindUser",
      "kind": "calls",
      "resolution": "static",
      "evidence": { "file": "handler/user.go", "line": 43 }
    }
  ]
}
```

**Note:** The IDs above are for illustration only. The implementation needs stable, collision-resistant identifiers that account for receivers, type parameters, declaration locations, build constraints, and related factors. `resolution: static` is too coarse to express certainty adequately; the actual model should distinguish confirmed, possible, and inferred relationships.

### Core Responsibilities

1. Validate nodes and edges and build indexes.
2. Query incoming/outgoing dependencies and n-hop neighborhoods.
3. Group and collapse elements, for example by package.
4. Store provenance and analysis evidence for navigating back to the source.
5. Save/load analysis results while leaving room for future graph diffs.

## 7. Go Analyzer Plugin

### Main Technologies

| Go Package / API | Primary Use |
| --- | --- |
| `go/parser` / `go/ast` | Parsing and traversing ASTs |
| `go/types` | Resolving types and identifiers |
| `golang.org/x/tools/go/packages` | Loading Go modules/packages under the relevant build configuration |
| `golang.org/x/tools/go/ssa` | More advanced analysis using SSA representations (later phase) |
| `golang.org/x/tools/go/callgraph` | Call graphs and CHA/RTA-style analyses (later phase) |

### What Static Analysis Can and Cannot Establish

| Analysis Target | Initial Expectation |
| --- | --- |
| Packages, files, and imports | Can generally be extracted with high accuracy |
| Type, function, and method definitions | Can generally be extracted with high accuracy |
| Direct function calls | Can be extracted with type information |
| Calls through interfaces | Static analysis may yield multiple possible callees |
| Function values, reflection, and dynamic registration | Exact resolution may be difficult or impossible |
| Exact runtime paths and functions actually invoked | Cannot be guaranteed by static analysis alone |

**Design rule:** Never confuse a relationship that **may exist** with one that was **actually observed**. If runtime traces are integrated later, represent them as a separate category of evidence from static-analysis results.

## 8. 3D Viewer Requirements

### Proposed Screen Layout

```text
+----------------------------------------------------------+
| Architecture Explorer       [Search]  [Filters] [View]  |
+----------------+---------------------------+-------------+
| Project Tree   |                           | Details     |
|                |       3D Graph View       |             |
| Packages       |                           | Node info   |
| Files          |   orbit / pan / zoom      | Edges       |
| Types          |   select / highlight      | Source      |
| Functions      |                           | Evidence    |
+----------------+---------------------------+-------------+
| status: analysis / node count / selected item            |
+----------------------------------------------------------+
```

### Essential Interactions

- Orbit, pan, and zoom the 3D camera.
- Select nodes and inspect their details.
- Highlight incoming and outgoing dependencies using distinct colors.
- Switch granularity between packages, types, and functions.
- Search by keyword and move the camera focus to a match.
- Show source file paths and line numbers (opening an editor can come later).

### Handling Large Graphs

Showing every node at once does not necessarily help humans understand a large codebase. Design for **level of detail (LOD)** from the beginning:

1. **Overview:** Show packages and subsystems.
2. **Intermediate:** Expand types, functions, and dependencies within a selected package.
3. **Detail:** Investigate references, calls, and provenance for an individual function or type.

Do not insist on pure 3D. Combine the spatial viewer with **2D/2.5D layouts and conventional detail panels**. The real goal is accurate, understandable exploration, not 3D rendering for its own sake.

## 9. Recommended Implementation Sequence

### Phase 0 — Scope and Contracts

- Define the minimum set of node and edge kinds for the MVP.
- Create a provisional JSON snapshot format.
- Prepare a small Go repository as a fixture for verification.

### Phase 1 — Odin Core + Sample Graph

- Open a native window using raylib.
- Render nodes and edges from a fixed JSON file.
- Implement camera controls, node selection, search, and related-node highlighting.
- Verify operation on NixOS/KDE.

**Completion criterion:** A saved graph can be explored interactively without a Go analyzer plugin.

### Phase 2 — Minimal Plugin Integration

- Launch and manage an external process.
- Receive analysis results over stdio, handle errors, and support protocol versioning.
- Use a stub plugin to test end-to-end host integration.

**Completion criterion:** The GUI can display a graph emitted by an external CLI.

### Phase 3 — Go Analyzer (First Production-Oriented Plugin)

- Collect package metadata and import dependencies using `go/packages`.
- Extract functions, methods, and types using AST and type information.
- Identify explicit calls and attach source locations.
- Emit `diagnostic` messages for locations that cannot be analyzed.

**Completion criterion:** A real Go repository can be selected and explored structurally in 3D.

### Phase 4 — Validation on Real Projects

- Measure layout, rendering, and search performance on repositories with thousands of nodes or more.
- Improve clustering, LOD, and filtering.
- Validate the correctness of extracted and displayed relationships.
- Stabilize only the plugin API surface that actual usage requires.

### Phase 5 — Future Extensions

- Show structural differences between Git commits, including added and removed dependencies.
- Run headless analysis in CI and generate snapshots.
- Enforce machine-checkable architecture rules, such as layer boundaries and cycle detection.
- Add analyzers for other languages (TypeScript, Java, Python, etc.).
- Integrate OpenAPI, IaC, and runtime traces (all explicitly out of scope for now).

## 10. Proposed Repository Layout

```text
architecture-explorer/
├── core/                     # Odin core
│   ├── graph/                # Graph model and queries
│   ├── plugin/               # Plugin process management
│   ├── layout/               # Spatial layout and clustering
│   ├── renderer/             # raylib rendering
│   ├── ui/                   # Desktop UI
│   └── snapshot/             # Save/load snapshots
├── plugins/
│   └── go-analyzer/          # Go analyzer plugin
├── schemas/
│   └── graph-v1.schema.json # Common graph contract (to be defined)
├── fixtures/                 # Sample Go projects and expected graphs
├── tests/
├── flake.nix                 # Planned NixOS development/build environment
└── README.md
```

## 11. Technology Trade-offs

| Option | Assessment |
| --- | --- |
| **Odin + raylib + Dear ImGui** | First choice. Supports the learning objective and a lightweight native application. Validate raylib/ImGui integration early in a PoC. |
| Rust + Bevy + egui | Strong ECS, language ecosystem, and type safety; an attractive alternative for long-term team development. |
| C++ + Qt Quick 3D | Mature GUI and 3D integration, but with added complexity and Qt licensing considerations. |
| Godot + C# | Good for rapidly prototyping rendering and interactions, but introduces substantial game-engine dependency. |
| Zig + raylib / sokol | Lightweight with fine-grained control, but Odin better matches the motivation for this project. |

**Current decision:** Use Odin for the core and Go for the first analyzer. If high-level UI work, rendering performance, or NixOS compatibility turns out to be significantly more difficult than expected, reconsider the rendering layer.

## 12. Technical Risks and Validation Questions

1. **Layout quality:** Will graph placement remain understandable as the number of nodes grows?
2. **Cognitive load:** Could 3D make relationships harder to interpret? Compare against 2D alternatives.
3. **Analysis accuracy:** Avoid presenting uncertain results as definite, particularly for interfaces, function values, and build tags.
4. **Performance:** Benchmark node/edge counts, label rendering, searching, and hit testing.
5. **Platform dependencies:** Test raylib/ImGui integration, NixOS/Wayland/X11, and graphics drivers.
6. **Plugin security:** Consider untrusted plugin execution, external dependency downloads, and proprietary source code confidentiality.
7. **Reproducibility:** Record analyzer versions, Git commits, and Go build conditions.
8. **Schema evolution:** Treat the initial JSON format as experimental and formally version it when compatibility becomes a requirement.

## 13. MVP Definition of Done

- [ ] The native Odin GUI launches locally.
- [ ] A saved JSON graph can be loaded and explored in 3D.
- [ ] Mouse controls work for the camera, and nodes can be selected.
- [ ] Incoming/outgoing dependencies and source locations can be inspected for a selected node.
- [ ] The Go analyzer plugin runs as a separate process.
- [ ] Packages, imports, definitions, and direct calls can be extracted from a Go repository.
- [ ] Relationships that cannot be resolved are not misrepresented as confirmed.
- [ ] `scan` and `view` can be used independently.
- [ ] Viewing a snapshot works without an internet connection or browser, given locally available dependencies.

## 14. Design Principles at This Stage

1. **Source First:** Source code is authoritative; the graph is derived data.
2. **Evidence First:** Preserve evidence and provenance for displayed dependencies.
3. **Local First:** Do not require the web or cloud.
4. **Language-Agnostic Core:** Keep language-specific semantic analysis in plugins.
5. **Renderer Independence:** Do not mix 3D coordinates or UI styling into the graph model.
6. **Progressive Disclosure:** Reveal details through exploration instead of displaying everything at once.
7. **Small Core, Real Plugin:** Prioritize a working Go plugin over a fully generalized framework.
8. **No False Certainty:** Distinguish static-analysis estimates from established facts.

---

**Next concrete step:** Build an Odin + raylib PoC that renders a fixed JSON graph in 3D and supports node selection. Then connect an out-of-process Go Analyzer.
