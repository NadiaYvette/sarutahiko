# **Reimplementing Tree-sitter and Ctags in Haskell**

[https://gemini.google.com/app/1ac2ec37f5066213](https://gemini.google.com/app/1ac2ec37f5066213)

&nbsp;

*User prompt: How does tree-sitter do its incremental parsing, as I'm thinking of reimplementing it in a new language. Also, how does ctags do what it does and what is it doing, also with an eye toward reimplementation in another language? The foreign calls create runtime system \-level concurrency and other issues, and it might also be worthwhile to use some advanced language features in Haskell.*

Response: Reimplementing Tree-sitter and Ctags natively in a language like Haskell is a compelling project. Avoiding C foreign-function-interface (FFI) overhead eliminates runtime-thread pinning, cross-boundary allocations, and memory safety invariants across C and Haskell's multi-threaded runtime system (RTS). Furthermore, purely functional data structures naturally align with incremental syntax trees.

## **1\. How Tree-Sitter Does Incremental Parsing**

Tree-sitter is an implementation of **Incremental Generalized LR (GLR)** parsing, based heavily on research by Tim Wagner and Susan Graham (*"Efficient and Flexible Incremental Parsing"*, 1998).

Standard LR parsers consume a stream of *terminal tokens* from a lexer and perform shift and reduce operations against a precompiled parse table. Tree-sitter modifies this loop to consume a stream of **both tokens and pre-parsed subtrees**.

### **The Core Mechanics**

`Text Edit Applied`&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`│`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`▼`  
`1. Mark Damaged Subtrees (Adjust byte offsets / invalidate overlapping nodes)`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`│`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`▼`  
`2. Incremental Parse Loop:`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`┌─► Can we shift an intact subtree from the old CST?`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`│     ├── YES ──► Shift subtree directly onto stack; advance cursor past it`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`│     └── NO  ──► Break open subtree into children; re-lex / parse terminals`  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`└─ Re-synchronized? (Stack state & lookahead match old tree) ──► Resume fast reuse`

#### **Step 1: The Concrete Syntax Tree (CST) Representation**

Every node in Tree-sitter’s tree stores:

> * A **symbol ID** (terminal token or non-terminal grammar rule).  
> * **Byte offsets / lengths** (for position tracking).  
> * **Parse state metadata**: The starting parser state and the parse state after the node was reduced.

#### **Step 2: Edit Invalidation and Damage Tracking**

When a file is edited, the host application informs the parser of the edit:

> * start\_byte, old\_end\_byte, and new\_end\_byte.

Tree-sitter walks down the existing CST to mark **damaged nodes**. Any node intersecting the edited range has its byte offsets adjusted and is flagged as invalid. Nodes located entirely after the edit simply have their byte offsets shifted by Δ=new\_end\_byte−old\_end\_byte.

#### **Step 3: Reusing Subtrees During the Parse Loop**

When parsing begins:

> 1. **Subtree Shifting**: Instead of immediately invoking the lexer for the next character, the parser checks the old tree at the current text position.  
> 2. If an intact, undamaged node exists at that position, and the parser’s current state table allows a shift on that non-terminal symbol with the appropriate lookahead, the parser **shifts the entire subtree in *O*(1) time**.  
> 3. The input cursor skips forward by the entire byte length of that shifted subtree.

#### **Step 4: Breaking Down Damaged Nodes**

If the node at the current offset is damaged (or cannot be shifted because the parser state changed):

> * The parser **breaks open** the node, descending into its children.  
> * It exposes smaller subtrees or raw terminal tokens until it reaches the exact region where new text was typed.  
> * Standard terminal lexing and parsing occur in this region.

#### **Step 5: Re-synchronization**

As soon as the parser moves past the edit region and its internal state matches the state recorded in an undamaged node of the old CST, the parser **re-synchronizes**. From that point forward, it shifts remaining top-level structures (such as subsequent function declarations) in constant time.

#### **GLR and Error Recovery**

> * **GLR Branching**: When the parse table has shift/reduce or reduce/reduce conflicts, Tree-sitter forks its parse stacks (similar to Tomita's algorithm). It carries these branches forward until dynamic precedence resolves the ambiguity.  
> * **Error Recovery**: If no valid transition exists, Tree-sitter does not abort. It creates an ERROR node, enters an error-recovery mode where it selectively discards tokens or inserts missing virtual tokens, and attempts to find a synchronization token (e.g., ;, }) to resume normal parsing.

## **2\. How Ctags Works (And What It Is Doing)**

While Tree-sitter builds a full concrete syntax tree, ctags (both Exuberant Ctags and Universal Ctags) has a different goal: **fast, shallow index generation** for code navigation.

### **The Inner Workings of Ctags**

A standard tags file is an index mapping symbol identifiers to their definition locations:

`tag_name<TAB>file_path<TAB>/^regex_search_pattern$/;"<TAB>kind<TAB>scope_info`

#### **1\. Shallow, State-Machine Lexing (Not Full Parsing)**

Historically, full language parsers were considered too slow and brittle for large codebases. Ctags typically uses:

> * **Hand-rolled Finite State Machines (FSMs)**: Light C-based tokenizers that track basic lexical delimiters (braces { }, parentheses, indentation) and keyword triggers (class, def, fn, struct).  
> * **Regex parsers (Optlib)**: Universal Ctags lets languages be defined purely using regular expression patterns that capture definition lines.

Because it does not build an AST, traditional Ctags can parse syntactically invalid or partially written files without failing—it simply scans for patterns.

#### **2\. Scope Tracking**

Modern Universal Ctags tracks structural hierarchy via a lightweight **scope stack**:

> * Entering a { or indented block after a class Foo pushes class:Foo onto a scope stack.  
> * Definitions parsed within that block inherit Foo as their parent scope (e.g., scope:class:Foo).  
> * Exiting the block pops the scope.

#### **3\. Modern Convergence (Tree-sitter Queries)**

Ad-hoc regexes and state machines break down when languages have complex syntax (e.g., C++ templates, Rust macros). Consequently, Universal Ctags added support for Tree-sitter parsers under the hood.

Instead of hand-rolling parsers, modern indexing runs declarative queries (like Tree-sitter's tags.scm S-expression patterns) against an AST:

`(function_item`  
&nbsp;&nbsp;`name: (identifier) @name`  
&nbsp;&nbsp;`parameters: (parameters) @context) @definition.function`

## **3\. Reimplementation Considerations in Haskell**

Haskell is well-suited for this domain because Wagner-Graham incremental parsing requires **persistent data structures with structural sharing**, which is Haskell’s default paradigm.

&nbsp;

| Component | C / Imperative Challenge | Haskell Advantage |
| :---- | :---- | :---- |
| **CST Sharing** | Must manage explicit reference counting, pointer swapping, and arena allocators. | Immutable data structures provide structural sharing out-of-the-box without memory corruption risks. |
| **Damage Tracking** | In-place mutation of offsets across trees requires deep pointer chasing. | **Monoidal Annotations**: Using a finger tree or 2-3 tree where node metrics (byte counts, line breaks) are cached monoids. Updating an offset is an *O*(log*n*) split and re-fold. |
| **GLR Forks** | Cloning stack frames and managing fork/join pointer graphs requires manual tracking. | Parser state branches can be modeled naturally using non-determinism monads (e.g., LogicT or list monads). |
| **Ctags Extraction** | Iterating through nested struct arrays with manual string builders. | Expressed as an AST fold / catamorphism or via generic scrap-your-boilerplate/lens traversals (uniplate, lens). |

### **Recommended Haskell Architecture**

> 1. **Parse Tree Representation**: Store the CST as a rose tree annotated with a monoid that summarizes both node length and whether the node contains damage:  
>    `data NodeInfo = NodeInfo`  
>    &nbsp;&nbsp;`{ nodeSpan       :: {-# UNPACK #-} !Span`  
>    &nbsp;&nbsp;`, nodeSymbol     :: {-# UNPACK #-} !SymbolId`  
>    &nbsp;&nbsp;`, nodeStartState :: {-# UNPACK #-} !StateId`  
>    &nbsp;&nbsp;`, nodeEndState   :: {-# UNPACK #-} !StateId`  
>    &nbsp;&nbsp;`}`

>    `data Tree = Leaf NodeInfo | Branch NodeInfo [Tree]`

> 2. **Grammar & Table Compilation**: Avoid generating parse tables at runtime. Use Template Haskell or an external compile-time build step to turn grammar definitions (e.g., grammar DSL or JSON definitions) into unboxed lookup arrays (Data.Array.Unboxed or vector tables) representing the LR action/goto tables.  
> 3. **Indexing Engine (Ctags Replacement)**: Rather than writing brittle regex state machines, define a pattern-matching DSL or query interpreter over your Haskell CST. Symbol generation then becomes a pure query run:  
>    `extractTags :: Tree -> [Tag]`

Are you looking to generate parsers from Tree-sitter's existing grammar.js files, or are you planning to define grammars natively using a Haskell DSL?

---

*User prompt: I would be sorely tempted to use some real database tables in lieu of ctags' and hoc disc format so that indexing in various ways can be carried out efficiently on large bodies of code. I already have large-records/large-anon/large-generics support for a wide variety of code now only interfacing with vinyl including large-anon support for beam, porcupine (docrecords/record-soup), and have a wide variety of network protocols and file formats queued up for imminent implementation beyond those. Could tree-sitter and ctags also fit into an extensible records ecosystem sweep?*

Response: Moving Tree-sitter extraction and tag generation into a relational database via an extensible records architecture is not just viable—it is exactly where the frontier of semantic code analysis is heading.

The industry is currently migrating away from ad-hoc flat files (like the traditional tags format) toward rich, relational code knowledge graphs. Recent architectures built for AI code agents (such as Codebase-Memory and CodeRLM) parse syntax trees using Tree-sitter and dump the extracted symbols, call sites, and containment edges directly into relational databases like SQLite. This enables recursive, SQL-backed exploration of call graphs and structural dependencies rather than relying on brittle grep or rigid text formats.

Integrating this with your existing large-records, large-anon, and beam stack provides a remarkably elegant way to solve the fundamental data-modeling problem of multi-language syntax trees: **the "Wide Node" problem.**

### **The Extensible Records Advantage for ASTs**

When you extract tags or AST nodes across a dozen languages, the schema requirements explode. A Go method needs a receiver\_type, C++ needs template\_args, Python needs decorators, and Haskell needs typeclass\_constraints.

If you use standard Haskell data types or standard beam tables, you are forced into either an untyped JSON blob column, a massive monolithic record with mostly Nothing fields, or an unwieldy hierarchy of relational joins.

By leveraging large-anon and beam-large-records, you can embrace a polymorphic row architecture:

> 1. **Base Schema**: You define a strict, universally applicable core record (e.g., NodeId, FileId, StartByte, EndByte, SymbolType).  
> 2. **Anonymous Extensions**: Using large-anon, you dynamically compose the core record with language-specific or domain-specific fields at compile time.  
> 3. **Type-Safe Persistence**: Because beam-large-records provides beam integration for these scalable records, you can directly map these wide, composed rows into your database schemas without the quadratic compilation blowup that usually plagues GHC when dealing with massive records.

### **The Architecture Pipeline**

If you sweep Tree-sitter and tags into your vinyl / large-records ecosystem, the pipeline looks like this:

#### **1\. The Tree-Sitter Extraction Phase**

Tree-sitter uses an S-expression query language (e.g., tags.scm) to pattern-match against the Concrete Syntax Tree (CST). Instead of formatting these matches into a Ctags text string, your Haskell ingestion engine captures them.

#### **2\. The Record Construction Phase**

Using porcupine and your record-soup abstractions, you stream these raw captures and project them into highly specific anonymous records. For example, an extraction pipeline could yield a type like: Record (CoreTagFields \++ HaskellSpecificFields \++ GitMetadataFields)

#### **3\. The Relational Mapping Phase**

Using beam-large-records, these wide records seamlessly project into a database schema. You can maintain a highly normalized graph architecture:

> * **nodes table**: Stores the universal syntax identifiers and byte spans.  
> * **edges table**: Stores structural relationships (e.g., CONTAINS, CALLS, IMPLEMENTS).  
> * **Language-specific extension tables**: Store the extended anonymous fields, optionally queried via SQL JOINs or PostgreSQL JSONB if you prefer a hybrid document-relational approach.

### **Why This Outperforms Ctags**

Standard Ctags only tells you *where* a symbol is defined. A relational database populated by Tree-sitter allows you to write type-safe beam queries for structural questions that Ctags cannot answer:

> * *"Find all functions that accept a parameter of type X and are called within module Y."*  
> * *"Return the structural differences (deleted AST nodes) between two Git commits."*  
> * *"Extract all HTTP route handlers and link them to their configuration constants."*

By treating source code as just another structured file format to be parsed and streamed into large-anon records, you unify your toolchain. The same machinery you are using to ingest network protocols and log files can ingest the semantic structure of the code itself, providing a strictly typed, queryable database of your entire repository.

**Sources**

> 1. [Codebase-Memory: Tree-Sitter-Based Knowledge Graphs for LLM](https://arxiv.org/html/2603.27277v1?utm_source=gemini)  
> 2. [GitHub \- well-typed/large-records](https://github.com/well-typed/large-records?utm_source=gemini)

---

*User prompt: Would the large-anon support for the beam package smooth the relational mapping phase by avoiding proliferations of schemas or in other ways?*

Response: Using large-anon to back the beam package fundamentally transforms the relational mapping phase by shifting the ORM paradigm from nominal typing to structural typing. In a standard Haskell database stack, parsing Abstract Syntax Trees (ASTs) across multiple languages inevitably leads to an explosion of boilerplate. large-anon neutralizes this at the compiler level and completely changes how you map code to tables.

Here is how that integration smooths the mapping phase and prevents schema proliferation:

### **1\. Eliminating Nominal Type Proliferation for Projections**

In standard beam, every table, join, and projection requires a formally declared nominal data type parameterized over a column tag (the f parameter). If you want to query just the symbol\_name, start\_byte, and file\_path across a join of the symbols and files tables, you are traditionally forced to return an unwieldy tuple or define a bespoke data SymbolLocationT f just for that one query.

With large-anon backing beam, you execute the query and project the result directly into an anonymous record: Record '\[ "symbol\_name" ':= Text, "start\_byte" ':= Int32, "file\_path" ':= Text \]. This allows you to write hundreds of specialized AST queries (e.g., extracting C++ template arguments vs. extracting Haskell typeclass constraints) without littering your codebase with single-use data declarations.

### **2\. Solving the "Wide Table" vs. "Sparse Column" Dilemma**

When representing different programming languages in a relational database, you face a modeling dilemma. You can use:

> * **One giant sparse table** with hundreds of nullable columns (e.g., has\_receiver, is\_monadic, memory\_safe).  
> * **Dozens of specialized extension tables** mapped one-to-one with a core ast\_nodes table.

large-anon makes both approaches painless in Haskell. If you use a wide table, row polymorphism allows your Haskell functions to operate only on the subset of fields they care about. A function calculating cyclomatic complexity only demands a record with HasField "branch\_count" r, ignoring whether the row also contains Rust-specific lifetime annotations. If you use extension tables, you can perform a SQL JOIN and dynamically merge the records in Haskell via row concatenation (\<+\>), yielding a single unified anonymous record without defining a new type for the joined result.

### **3\. Bypassing GHC's Quadratic Compilation Limits**

A comprehensive CST/AST schema representing the entirety of a language's grammar will easily exceed 50 to 100 fields when accounting for spatial metadata, scope resolution, and parsing state. Standard GHC records degrade to *O*(*n*2) compile times with records this size. large-anon (and large-records) uses GHC plugins and type-level dictionaries to maintain linear compile times.

When piping Tree-sitter outputs directly into beam, you can define massive schemas that accurately reflect the complexity of a language grammar without crashing GHC or suffering minute-long compile times per module.

### **4\. Seamless Pipelining with Porcupine**

Because you have also integrated large-anon with porcupine (record-soup), your data ingestion pipeline loses all impedance mismatch. The flow becomes entirely structural:

> 1. **Extract:** Read raw Tree-sitter nodes as a loosely typed record soup.  
> 2. **Transform:** Use row-polymorphic functions to validate, rename, or cast fields (e.g., normalizing 0-indexed Tree-sitter byte offsets to your internal standard).  
> 3. **Load:** Pass the resulting anonymous record directly to your beam insert statements.

There is no mapping layer where you unpack a porcupine soup into a nominal Haskell datatype, only to repack it into a beam table type. The anonymous record simply flows from the Tree-sitter FFI, through the pipeline, directly into the PostgreSQL/SQLite driver.

---

*User prompt: How would the database itself need to be indexed in such a scenario? (I suspect apart from large-anon reducing compilation times, most of the advantages would be shared by vinyl.) I'm not entirely sure how the more orthodox databases are indexed, but I think there might be some ways that ragged records/rows need to be accommodated but I don't remember how.*

Response: You are completely correct about vinyl. From a structural and type-theoretic standpoint, vinyl and large-anon share the exact same row-polymorphism benefits. The critical divergence is purely mechanical: vinyl relies on standard GHC type-level lists, which exhibit *O*(*n*2) compile-time complexity as the record grows, while large-anon uses GHC plugins and dictionary generation to keep compilation times linear for massive schemas.

When you map these "ragged" records (where a C++ AST node has 20 fields that a Python node lacks, and vice versa) into an orthodox relational database like PostgreSQL, the indexing strategy must shift to accommodate both the sparse data and the spatial nature of a syntax tree.

Here is how a relational database must be indexed to handle this architecture efficiently.

## **1\. Indexing Ragged / Sparse Data**

Orthodox databases default to B-Tree indexes, which index every row in a table. If you use a "Wide Table" approach for your ragged records (one table with hundreds of language-specific nullable columns), standard B-Trees will heavily bloat the database by indexing millions of NULL values.

To accommodate ragged rows, you rely on these indexing strategies:

### **Partial Indexes**

PostgreSQL allows you to build an index on a column *only* where data actually exists. If your anonymous record has a field for rust\_lifetime\_annotation, you create an index explicitly filtering out NULLs:

`CREATE INDEX idx_rust_lifetimes ON ast_nodes (rust_lifetime)`&nbsp;  
`WHERE rust_lifetime IS NOT NULL;`

This keeps the index incredibly small and fast. When your beam query looks for a specific Rust lifetime, the query planner recognizes the IS NOT NULL implication and uses this tiny, specialized index, entirely ignoring the millions of rows of Haskell and C code.

### **GIN Indexes over JSONB (The Hybrid Approach)**

If the schema proliferation of a Wide Table becomes too extreme, the standard practice is a hybrid model: strongly type the "core" universal fields (ID, file, byte\_range, node\_type) as standard columns, and pack the ragged, language-specific fields into a single JSONB column.

> * **The Index:** You apply a **GIN (Generalized Inverted Index)** to the JSONB column:  
>   `CREATE INDEX idx_ragged_props ON ast_nodes USING GIN (language_specific_props);`

> * **The Haskell Side:** Your porcupine pipeline uses large-anon to statically verify the fields in Haskell, but serialization packages them into a JSON blob for insertion. The GIN index allows fast querying of arbitrary keys inside that blob without needing a predefined schema column.

## **2\. Indexing for AST Spatial Geography**

Tree-sitter and Ctags queries are inherently spatial. You frequently need to answer: *"What function definition encloses the cursor at byte offset 14,502?"*

Standard (start\_byte, end\_byte) columns indexed via B-Tree are remarkably inefficient for overlap queries.

### **GiST and Range Types**

Instead of two separate integer columns, PostgreSQL provides native int4range or int8range types. You index these using a **GiST (Generalized Search Tree)** index:

`CREATE INDEX idx_node_byte_range ON ast_nodes USING GiST (byte_span);`

GiST indexes use bounding-box logic (R-trees). This allows beam to execute *O*(log*n*) queries for spatial overlaps, such as finding the most deeply nested AST node containing a specific byte location, which is exactly what an editor requires when a user clicks "Go to Definition."

## **3\. Indexing the Hierarchy (The Tree Structure)**

ASTs are deeply nested graphs. If you want to replace Ctags' scope-tracking (e.g., finding all methods within class Foo), you must traverse parent-child relationships efficiently.

### **Materialized Paths (ltree)**

Joining a table to itself recursively to traverse an AST is slow. Orthodox databases accommodate deep trees using materialized paths, often via an extension like PostgreSQL's ltree.

> * Each row stores a path string: root\_id.namespace\_id.class\_id.method\_id.  
> * You apply a GiST or GIN index to this path column.  
> * This allows a single, non-recursive query to instantly retrieve an entire subtree (e.g., "fetch all AST nodes that are descendants of class\_id").

### **The Synthesis in Haskell**

By combining large-anon with beam (specifically beam-postgres), you map your highly typed, ragged Haskell records to a schema optimized with **Partial Indexes** (for language-specific fields) and **GiST/Range Indexes** (for Tree-sitter byte ranges). The database handles the sparse reality of the data at the storage layer, while your Haskell pipeline interacts with it as perfectly structured, strongly typed records.

---

