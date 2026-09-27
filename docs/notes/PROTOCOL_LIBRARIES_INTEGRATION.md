# Protocol Libraries Integration — TUF Supply-Chain Security & Anonymous Federated Transport

Status: DRAFT v0.1 · 2026-09-27 (architectural integration note)
Related: `NIH_PLAN.md` (program architecture), `EFFECT_CATALOG_DESIGN.md` (algebraic effect catalog), `REUSE_REGISTER.md` (third-party dependencies), `docs/notes/DESIGN_REVIEW_GEMMA4-A12B.md`
Sources: `~/src/hackage-security/` (TUF implementation in Haskell), `~/src/haskell-tor/` (Galois `haskell-tor` implementation), `typed-protocols` (`~/src/typed-protocols/`)

---

## 1. Context & Architectural Rationale

As `sarutahiko` evolves into a fully autonomous agent framework, its execution envelope extends beyond local tool invocation to dynamic skill acquisition, WASM tool fetching, remote plugin installation, and cross-node agent federation. These capabilities introduce two major security and privacy vectors:

1. **Supply-Chain Integrity Vector:** Dynamic loading of external code, skill packs, and tool manifests exposes agent runtimes to man-in-the-middle (MitM) tampering, malicious package substitution, and key compromise.
2. **Metadata & Privacy Vector:** Direct HTTP/WebSocket connections between federated agent nodes expose IP addresses, topology, traffic patterns, and operational metadata to eavesdroppers and network observers.

To address these vectors without reinventing cryptographic protocol primitives, `sarutahiko` adopts a principled doctrine of folding mature, high-assurance Haskell protocol libraries—specifically `hackage-security` (The Update Framework, TUF) and `haskell-tor` (Galois' onion-routing engine)—into row-typed effect interfaces.

---

## 2. Supply-Chain Security via TUF (`hackage-security`)

### 2.1 The Update Framework (TUF) Core Invariants
`hackage-security` implements TUF (RFC 8738 / TUF specification v1.0), protecting against:
- **Arbitrary Code Execution / Malicious Updates:** Via multi-role threshold signatures (Root, Targets, Snapshot, Timestamp).
- **Rollback Attacks:** Verifying snapshot versions and expiration timestamps.
- **Freeze Attacks:** Requiring short-lived signed timestamp updates.
- **Key Compromise:** Separating offline root keys from online timestamp/snapshot keys.

### 2.2 Integration into `sarutahiko`
We encapsulate `hackage-security` within an abstract `TufVerify` effect signature:

```haskell
data TufVerify m a where
  UpdateRepositoryKeys :: RepositoryKeyMap -> TufVerify m ()
  VerifyPackageIndex   :: IndexTarget -> RawBytes -> TufVerify m (Either TufError VerifiedIndex)
  VerifyToolBinary     :: ToolId -> FilePath -> TufVerify m (Either TufError ToolManifest)
```

**Key Integration Strategy:**
- **Zero Raw DTO Leakage:** Internal `hackage-security` state structures are mapped into `large-anon` records wrapped in `WireEnvelope`.
- **Sandbox Validation:** Before an agent executes a dynamically downloaded skill or tool (e.g. from a remote registry or GitHub release), the `TufVerify` effect validates the package against the trusted root role before passing the binary to `sarutahiko-process`.

---

## 3. Anonymous Peer-to-Peer Transport via `haskell-tor`

### 3.1 Galois `haskell-tor` Capabilities
`haskell-tor` provides a pure and effectful implementation of the Tor v2/v3 onion-routing protocol in Haskell:
- Cryptographic circuit construction (DH/ECDH key exchange, AES-CTR cell encryption).
- Hidden service client/server rendezvous protocol.
- Tor directory protocol parsing and consensus state management.

### 3.2 Integration into `sarutahiko`
Agent-to-agent federation requires un-linkable, peer-to-peer transport that operates cleanly through strict NATs and firewalls without revealing agent location or IP metadata. We define `TorTransport` effect signatures in `sarutahiko-effect-signatures`:

```haskell
data TorTransport m a where
  CreateCircuit    :: CircuitSpec -> TorTransport m CircuitId
  ConnectOnion     :: OnionAddress -> Port -> TorTransport m (TorSocket m)
  BindOnionService :: ServiceKey -> Port -> TorTransport m (OnionAddress, EventCursor m TorConnection)
```

**Key Integration Strategy:**
- **Streaming & Cursor Unification:** Connection accept streams leverage `EventCursor m TorConnection`, integrating seamlessly with `yamaarashi`'s Tier-0 streaming kernel and `Scoped` resource management.
- **Typed Protocol State Machines:** Circuit lifecycle states (`Unbuilt`, `Connected`, `Rendezvous`, `Closed`) are indexed via type-level state markers to prevent out-of-order packet transmission or circuit misuse.

---

## 4. Integration Roadmap & Effect Boundary Summary

| Library Source | `sarutahiko` Effect Package | Key Interface | Role in Agent Runtime |
|---|---|---|---|
| `~/src/hackage-security/` | `sarutahiko-effect-signatures` | `TufVerify` | Verifies skill, tool binary, and schema repository signatures before execution. |
| `~/src/haskell-tor/` | `sarutahiko-effect-signatures` | `TorTransport` | Anonymous peer-to-peer inter-agent communication and hidden-service endpoints. |
| `~/src/typed-protocols/` | `sarutahiko-jsonrpc` / `sarutahiko-mcp` | `ProtocolState` | Type-level peer-to-peer session state machine validation for MCP and JSON-RPC. |

---
