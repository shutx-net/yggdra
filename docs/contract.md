# Graph Contract v0

This document defines the record stream that an analyzer writes and the core reads. The same stream is both the analyzer's standard output and the content of a saved snapshot. How the core starts the analyzer, and what stderr and the exit status mean, is described in [initial-plan.md §5](initial-plan.md#5-analyzer-integration).

`schema_version` is `0`: experimental, with no compatibility promise. Readers reject every other version. Any change to this document changes the analyzer, the core, the fixtures, and the tests in the same commit. The version becomes `1` when compatibility is first promised.

## Stream

- The stream is UTF-8 text with one record per line. Each line is one JSON object ([RFC 8259](https://www.rfc-editor.org/rfc/rfc8259)) and ends with a line feed, including the last line. Empty lines are invalid. JSON strings cannot contain a raw line break, so a reader can split the stream into lines before parsing.
- Records appear in this order: one `header`, all `node` records, all `edge` records, all `diagnostic` records, and one `complete`. Nothing follows `complete`. A stream that ends before `complete` is truncated and is rejected.
- Because nodes come before edges, a reader can check every reference in an edge as soon as it reads the edge.
- When the core saves a snapshot, it validates the whole stream first and then writes the analyzer's bytes unchanged. It never re-encodes records, so only the analyzer has to produce the canonical form.

## Values

- **Keys:** Every key a record may contain is listed below. Readers reject unknown keys and duplicate keys. The one exception is `header.context`: each analyzer defines its keys, and the core accepts them without knowing them. Duplicate keys are rejected there too.
- **Absent values:** A field without a value is omitted. `null` is never valid.
- **`external`** is omitted unless it is `true`. Writing `false` is invalid, so that each node has only one encoding.
- **Strings:** After unescaping, every string is valid UTF-8 and contains no U+0000. Strings described as non-empty must not be `""`.
- **Integers:** Integers are written in decimal, without a fraction or an exponent, and lie between 0 and 2147483647 (2³¹ − 1). `line` and `col` are at least 1.

## Records

Each table lists the keys in canonical order.

### `header`

| Key | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `type` | `"header"` | Required | |
| `schema_version` | integer | Required | `0` |
| `analyzer` | object | Required | `name` and `version` of the analyzer, both non-empty strings, in that order |
| `context` | object | Required | The analysis configuration. Keys are defined by the analyzer; values are strings, booleans, or arrays of strings |

- Readers check `schema_version` before anything else in the header, so an unknown version is reported as such and not as a missing key.
- The core shows `context` to the user but does not interpret it. This lets each analyzer describe its configuration without the core containing language-specific code.
- `context` holds no timestamps, host names, user names, or absolute paths. A VCS revision may appear only when the working tree matches it exactly.

### `node`

| Key | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `type` | `"node"` | Required | |
| `id` | string | Required | Non-empty and unique in the stream. The core compares IDs bytewise and does not interpret them |
| `kind` | string | Required | `package`, `type`, `interface`, `function`, or `method` |
| `name` | string | Required | Non-empty display name |
| `parent` | string | Required except for packages; absent for packages | The ID of the containing node |
| `external` | `true` | Optional | The node lies outside the analyzed code |
| `dir` | string | Required for packages that are not external; absent otherwise | The package's directory. The core groups packages by directory from this field |
| `loc` | [location](#locations) | Required for types, interfaces, functions, and methods that are not external; absent otherwise | The position of the declaration's name |

- **Containment:** The parent of a type, interface, or function is a package. The parent of a method is a type or an interface. The containment tree is therefore at most three levels deep and cannot contain a cycle.
- `interface` is a separate kind from `type` because a call to an interface method does not identify the code that runs.
- A node and its parent are either both external or both not external.
- External nodes have no `dir` or `loc`. Their files lie outside the root, at machine-specific paths.
- Files are not nodes. Every declaration carries its file in `loc`.

### `edge`

| Key | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `type` | `"edge"` | Required | |
| `kind` | string | Required | `imports` or `calls` |
| `source` | string | Required | The ID of the node the relationship starts at |
| `target` | string | Required unless `certainty` is `unresolved`; absent then | The ID of the node the relationship points to |
| `certainty` | string | Required | `established` or `unresolved` |
| `sites` | array of [locations](#locations) | Required | Every place in the source that supports the edge. At least one, no two equal |

- **`imports`:** The source and the target are packages, and the certainty is `established`.
- **`calls`:** The source is a function, a method, or a package (for calls in package-level initializers). The target, when present, is a function or a method.
- No edge starts at an external node.
- An edge is identified by (`kind`, `source`, `target`) and appears at most once. Every occurrence of the relationship is one of its sites. An unresolved edge has no target, so all unresolved calls made by one declaration form a single edge.
- Analyzers never emit edges between collapsed groups. The core derives those from the edges of their descendants.

Certainty has three values. v0 accepts only the first two.

| Value | Meaning |
| --- | --- |
| `established` | A fact of the source under the recorded configuration, proven by the type checker. |
| `unresolved` | The relationship exists, but its target cannot be named. |
| `inferred` | Reserved for approximations, such as candidate implementations of an interface method. Rejected in v0, because nothing produces it yet. |

There are no numeric confidence scores. Evidence observed at run time, if it is ever added, gets its own value and is never folded into these.

### `diagnostic`

| Key | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `type` | `"diagnostic"` | Required | |
| `severity` | string | Required | `error` or `warning` |
| `message` | string | Required | Non-empty. Contains no absolute paths |
| `loc` | [location](#locations) | Optional | Where the problem is, when it is known and inside the root |

- **`error`:** Part of the source could not be loaded or type-checked, so the graph lacks whatever that part would have contributed. A snapshot with error diagnostics is valid, but the viewer shows that the analysis is incomplete.
- **`warning`:** The graph is complete for the recorded configuration, but something deserves attention, such as files left out because the configuration excludes them.
- In a diagnostic's `loc`, `line` and `col` may be omitted when they are unknown. `col` may appear only together with `line`.
- The core cannot check `message` for paths. Keeping absolute paths out of it is the analyzer's obligation, enforced by the analyzer's tests.

### `complete`

| Key | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `type` | `"complete"` | Required | |
| `nodes` | integer | Required | The number of `node` records |
| `edges` | integer | Required | The number of `edge` records |
| `diagnostics` | integer | Required | The number of `diagnostic` records |

### Locations

A location is an object with these keys:

| Key | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `file` | string | Required | The file's path |
| `line` | integer | Required, except in diagnostics | 1-based line number |
| `col` | integer | Required, except in diagnostics | 1-based column, counted in bytes, not characters |

`file` and `dir` are paths relative to the analyzed root directory:

- Segments are separated by `/`. No segment is empty, `.`, or `..`, and the path does not start with `/`.
- `dir` is `.` for the root directory itself.
- Snapshots never contain absolute paths.

## Canonical Form

The same input and configuration produce byte-identical output. Writers:

- write keys in the order of the tables above, and the keys of `header.context` in bytewise order;
- write no whitespace outside strings;
- sort nodes by `id`;
- sort edges by (`source`, `kind`, `target`), with an absent target first;
- sort sites by (`file`, `line`, `col`);
- sort diagnostics by (`file`, `line`, `col`, `severity`, `message`), with absent values first, and drop exact duplicates;
- compare strings bytewise and integers numerically.

How strings are escaped is the writer's choice, as long as it does not vary between runs.

Readers do not check the canonical form: key order, whitespace, and sort order are not validated. The analyzer's golden tests check them.

## Validation

The core rejects a stream that breaks any rule in this document, and reports the 1-based line number and the rule. In particular, it rejects:

- a first line that is not a `header`, an unknown `schema_version`, records out of order, a missing `complete`, a line after `complete`, or an empty line;
- a line that is not one JSON object, invalid UTF-8, U+0000 in a string, or a value over the [limits](#limits);
- an unknown record type, an unknown or duplicate key, a missing required key, a key that must be absent, a value of the wrong type, `null`, or an unknown `kind`, `certainty`, or `severity`;
- a duplicate node ID or a duplicate edge;
- a `parent`, `source`, or `target` that names no node, or that names a node of a kind the rules above do not allow;
- a node whose `external` differs from its parent's, or an edge that starts at an external node;
- a target present on an `unresolved` edge or missing from any other edge, an empty `sites`, or two equal sites;
- an invalid path;
- counts in `complete` that do not match the records.

A reference error is reported on the line of the record that contains the reference. A count mismatch is reported on the line of `complete`.

## Limits

The same limits apply to an analyzer's output and to a saved snapshot. They are parameters of the reader, so tests can exceed small limits without large fixtures. The defaults below are provisional. They will be revised once snapshots of real projects have been measured (Phase 0).

| Limit | Default |
| --- | --- |
| Line length, excluding the line feed | 16 MiB |
| Records | 4,000,000 |
| Stream size | 1 GiB |
| Nesting depth of arrays and objects | 8 |

- Valid records nest at most three levels deep: a record, `sites`, and a site. A line within the length limit can still nest deeply enough to overflow the stack of a recursive parser, so readers check the depth before parsing a line.
- `sites` has no limit of its own, so the line length limit is also the limit on the sites of one edge. If a real project exceeds it, the limit is raised, or a contract change caps the sites and records how many were dropped.
- How much of the analyzer's stderr the core keeps is the core's own policy, not part of this contract.

## Go Analyzer Conventions

These rules apply to the Go analyzer only. The core does not depend on them. Which Go constructs become which nodes and edges is described in [initial-plan.md §7](initial-plan.md#7-go-analyzer).

### Root and Context

- `analyzer.name` is `go`.
- The root is the root directory of the module that contains the directory the analyzer was given.
- `context` contains exactly these keys:

  | Key | Type | Meaning |
  | --- | --- | --- |
  | `build_tags` | array of strings | Extra build tags, sorted. Empty if none |
  | `cgo_enabled` | boolean | Whether cgo was enabled |
  | `downloads` | boolean | Whether the `go` command was allowed to download modules or toolchains |
  | `go_version` | string | The version of the `go` command that loaded the packages, for example `go1.27.1` |
  | `goarch` | string | Target architecture |
  | `goos` | string | Target operating system |
  | `module` | string | The module path |

- `downloads` is recorded instead of the effective `GOPROXY` and `GOTOOLCHAIN` values, because those can name private hosts or contain credentials.
- Go's `encoding/json` writes a nil slice as `null`, which this contract rejects. An empty `build_tags` must be written as `[]`.

### Node IDs

IDs are stable across commits as long as a declaration keeps its package, receiver, and name.

| Node | ID |
| --- | --- |
| Package | `go:<import path>` |
| Type, interface, function | `go:<import path>#<Name>` |
| Method | `go:<import path>#<Type>.<Method>` |

- IDs never contain line numbers, file paths of ordinary declarations, or build configuration.
- Generic declarations use the uninstantiated declaration.
- Methods use the type that declares them, including methods reached through embedding.
- `init` functions are the exception to the file-path rule, because a package may have several: `go:<import path>#init@<file name>`, with an ordinal suffix when one file has more than one.
- Declarations named `_`, types declared inside functions, and function literals are not nodes. Calls made inside a function literal belong to the enclosing declaration.

### Names and Directories

- A package's `name` is the name in its package clause. When a package cannot be loaded, its `name` is the last element of its import path, and a diagnostic explains the failure.
- A package belongs to the analyzed code when it is in the analyzed module. Packages of other modules, including vendored ones, are external.
- The `dir` of a package in the module is its import path relative to the module path, or `.` for the package at the module root.

### Positions

- A declaration's `loc` is the position of its name.
- An `imports` site is the position of the import path's string literal.
- A `calls` site is the position of the call's opening parenthesis. Every call has exactly one, and no two calls share it.

### Paths in Messages

Before writing a diagnostic's `message`, the analyzer rewrites every absolute path in it:

| Path | Rewritten as |
| --- | --- |
| Inside the root | Relative to the root |
| Inside `GOROOT` | `$GOROOT/` followed by the rest of the path |
| Inside the module cache | `$GOMODCACHE/` followed by the rest of the path |
| Anywhere else | `$OUTSIDE` |

When a problem's position is outside the root, `loc` is omitted and the analyzer writes the rewritten position into `message`.

## Example

A module `example.com/app` with two packages and one type error:

```jsonl
{"type":"header","schema_version":0,"analyzer":{"name":"go","version":"0.0.0"},"context":{"build_tags":[],"cgo_enabled":false,"downloads":false,"go_version":"go1.27.1","goarch":"amd64","goos":"linux","module":"example.com/app"}}
{"type":"node","id":"go:example.com/app/handler","kind":"package","name":"handler","dir":"handler"}
{"type":"node","id":"go:example.com/app/handler#GetUser","kind":"function","name":"GetUser","parent":"go:example.com/app/handler","loc":{"file":"handler/user.go","line":42,"col":6}}
{"type":"node","id":"go:example.com/app/service","kind":"package","name":"service","dir":"service"}
{"type":"node","id":"go:example.com/app/service#Store","kind":"interface","name":"Store","parent":"go:example.com/app/service","loc":{"file":"service/store.go","line":9,"col":6}}
{"type":"node","id":"go:example.com/app/service#Store.Find","kind":"method","name":"Find","parent":"go:example.com/app/service#Store","loc":{"file":"service/store.go","line":10,"col":2}}
{"type":"node","id":"go:fmt","kind":"package","name":"fmt","external":true}
{"type":"edge","kind":"imports","source":"go:example.com/app/handler","target":"go:example.com/app/service","certainty":"established","sites":[{"file":"handler/user.go","line":6,"col":2}]}
{"type":"edge","kind":"imports","source":"go:example.com/app/handler","target":"go:fmt","certainty":"established","sites":[{"file":"handler/user.go","line":4,"col":2}]}
{"type":"edge","kind":"calls","source":"go:example.com/app/handler#GetUser","certainty":"unresolved","sites":[{"file":"handler/user.go","line":51,"col":20}]}
{"type":"edge","kind":"calls","source":"go:example.com/app/handler#GetUser","target":"go:example.com/app/service#Store.Find","certainty":"established","sites":[{"file":"handler/user.go","line":43,"col":18}]}
{"type":"diagnostic","severity":"error","message":"undefined: Cache","loc":{"file":"service/store.go","line":20,"col":9}}
{"type":"complete","nodes":6,"edges":4,"diagnostics":1}
```

## Rationale

- **Unknown keys are rejected.** v0 has no compatibility promise, and every change updates the analyzer and the core together, so tolerating unknown keys would buy nothing. Rejecting them catches misspelled keys and a producer and consumer that have drifted apart. `header.context` is the one place an analyzer extends the format. Whether to keep rejecting, or to add a general extension mechanism, is decided when the version becomes `1`.
- **One encoding per meaning.** Absent fields are omitted, `null` and `"external": false` are never written, and the core saves the analyzer's bytes unchanged. Equal inputs therefore give equal bytes, and golden tests can compare output byte for byte.
- **Sites are not capped.** Every displayed relationship keeps all of its evidence. The line length limit protects the reader instead, until measurements of real projects show whether a cap is needed.
