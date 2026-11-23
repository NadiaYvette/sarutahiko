#!/bin/sh
set -eu

echo "=== [TP-SARUTAHIKO-NORM-001] Starting repository normalization ==="

# ------------------------------------------------------------------------------
# 1. Remove orphan root cabal-init stub
# ------------------------------------------------------------------------------
echo "--- 1. Removing orphan root cabal-init files ---"
rm -f sarutahiko.cabal
rm -f app/Main.hs
rm -f src/MyLib.hs
rm -f test/Main.hs
rm -rf app src test

# ------------------------------------------------------------------------------
# 2. Relocate Yamaarashi.Scheduler.ConcurrentZ3Pool to yamaarashi package
# ------------------------------------------------------------------------------
echo "--- 2. Relocating Yamaarashi.Scheduler.ConcurrentZ3Pool ---"
mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/Scheduler
if [ -f packages/sarutahiko/sarutahiko-agent/src/Yamaarashi/Scheduler/ConcurrentZ3Pool.hs ]; then
  mv packages/sarutahiko/sarutahiko-agent/src/Yamaarashi/Scheduler/ConcurrentZ3Pool.hs \
     packages/yamaarashi/yamaarashi/src/Yamaarashi/Scheduler/ConcurrentZ3Pool.hs
  rm -rf packages/sarutahiko/sarutahiko-agent/src/Yamaarashi
fi

# Decouple ConcurrentZ3Pool from Sarutahiko.Orchestrator.CoEvolutionLoop
python3 - << 'EOF'
import sys

# 1. Update Yamaarashi/Scheduler/ConcurrentZ3Pool.hs
pool_path = "packages/yamaarashi/yamaarashi/src/Yamaarashi/Scheduler/ConcurrentZ3Pool.hs"
with open(pool_path, "r", encoding="utf-8") as f:
    pool_code = f.read()

# Replace export list of stepConcurrentCoEvolutionMachine with VertexSynthesisBundle & extractParetoDecisionTrees
old_export = """    -- * 4. Concurrent Phase 5: Parallel Ambiguity Quotienting Tournament
  , runParallelAmbiguityCheck
  , parallelSemanticQuotient
    -- * 5. Concurrent State-Machine Step Replacement
  , stepConcurrentCoEvolutionMachine
  ) where"""

new_export = """    -- * 4. Concurrent Phase 5: Parallel Ambiguity Quotienting Tournament
  , runParallelAmbiguityCheck
  , parallelSemanticQuotient
    -- * 5. Vertex Synthesis Bundle & Pareto Extraction
  , VertexSynthesisBundle (..)
  , extractParetoDecisionTrees
  ) where"""

if old_export in pool_code:
    pool_code = pool_code.replace(old_export, new_export)

# Replace import of Sarutahiko.Orchestrator.CoEvolutionLoop with self-contained definitions
old_import = """import Sarutahiko.Orchestrator.CoEvolutionLoop
  ( CoEvolutionPhase (..)
  , LLMTheoryOracle (..)
  , OrchestratorConfig (..)
  , OrchestratorMetrics (..)
  , OrchestratorState (..)
  , VertexSynthesisBundle (..)
  , extractParetoDecisionTrees
  , stepCoEvolutionMachine
  )"""

new_import = """import Control.Monad (forM)
import Data.Maybe (catMaybes)
import Gargamelle.Core.Institution.Liquid (RSchema, SymName)
import Gargamelle.Equational.AbductiveEGraph (DPORule (..), EClassData (..), extractVerifiedDecisionTree)"""

if old_import in pool_code:
    pool_code = pool_code.replace(old_import, new_import)

# Replace Section 5 with definitions of VertexSynthesisBundle and extractParetoDecisionTrees
sec5_marker = "--------------------------------------------------------------------------------\n-- 5. Concurrent State-Machine Step Replacement"

new_sec5 = r"""--------------------------------------------------------------------------------
-- 5. Vertex Synthesis Bundle & Multi-Cover Pareto Extraction
--------------------------------------------------------------------------------

data VertexSynthesisBundle = VertexSynthesisBundle
  { vsbVertexId        :: VertexId
  , vsbRootClass       :: EClassId
  , vsbGoalBase        :: RBase
  , vsbEGraph          :: AbductiveEGraph
  , vsbDPORules        :: [DPORule]
  , vsbComponents      :: Map SymName RSchema
  , vsbInventedSeps    :: [SeparatorSynthesisResult]
  , vsbCandidateTrees  :: [(SynTerm, Int)]
  , vsbDisambiguated   :: Maybe SynTerm
  , vsbZ3QueryCount    :: !Int
  } deriving stock (Generic)

extractParetoDecisionTrees
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3StreamSession
  -> EClassId
  -> RBase
  -> AbductiveEGraph
  -> IO [(SynTerm, Int)]
extractParetoDecisionTrees proxy session rootCid@(EClassId cid) goalBase eg = do
  mPrimary <- extractVerifiedDecisionTree proxy session rootCid goalBase eg
  case mPrimary of
    Nothing -> pure []
    Just primaryTree -> do
      let rootFrontier = maybe [] ecFrontier (IntMap.lookup cid (egClasses eg))
      altTrees <- fmap catMaybes $ forM [0 .. min 3 (length rootFrontier - 1)] $ \dropIdx -> do
        let maskedFrontier =
              [ c | (i, c) <- zip [0..] rootFrontier, i /= dropIdx ]
            egMasked = eg
              { egClasses = IntMap.adjust
                  (\ec -> ec { ecFrontier = maskedFrontier })
                  cid
                  (egClasses eg)
              }
        mAlt <- extractVerifiedDecisionTree proxy session rootCid goalBase egMasked
        pure $ fmap (\t -> (t, 10 + dropIdx)) mAlt
      pure ((primaryTree, 1) : altTrees)"""

pos = pool_code.find(sec5_marker)
if pos != -1:
    pool_code = pool_code[:pos] + new_sec5 + "\n"

with open(pool_path, "w", encoding="utf-8") as f:
    f.write(pool_code)

# 2. Update sarutahiko-agent CoEvolutionLoop.hs to import ConcurrentZ3Pool and provide stepConcurrentCoEvolutionMachine
loop_path = "packages/sarutahiko/sarutahiko-agent/src/Sarutahiko/Orchestrator/CoEvolutionLoop.hs"
with open(loop_path, "r", encoding="utf-8") as f:
    loop_code = f.read()

# Remove duplicate data VertexSynthesisBundle
v_start = loop_code.find("data VertexSynthesisBundle = VertexSynthesisBundle")
if v_start != -1:
    v_end = loop_code.find("deriving stock (Generic)\n", v_start)
    if v_end != -1:
        v_end += len("deriving stock (Generic)\n")
        loop_code = loop_code[:v_start] + loop_code[v_end:]

# Remove duplicate extractParetoDecisionTrees
e_start = loop_code.find("extractParetoDecisionTrees\n  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)")
if e_start != -1:
    e_end = loop_code.find("      pure ((primaryTree, 1) : altTrees)\n", e_start)
    if e_end != -1:
        e_end += len("      pure ((primaryTree, 1) : altTrees)\n")
        loop_code = loop_code[:e_start] + loop_code[e_end:]

# Add stepConcurrentCoEvolutionMachine to export list
if "  , stepCoEvolutionMachine" in loop_code and "  , stepConcurrentCoEvolutionMachine" not in loop_code:
    loop_code = loop_code.replace("  , stepCoEvolutionMachine", "  , stepCoEvolutionMachine\n  , stepConcurrentCoEvolutionMachine")

# Add import of Yamaarashi.Scheduler.ConcurrentZ3Pool
if "import Yamaarashi.Scheduler.ConcurrentZ3Pool" not in loop_code:
    loop_code = loop_code.replace("import Gargamelle.Model.AmbiguityOracle", """import Yamaarashi.Scheduler.ConcurrentZ3Pool
  ( VertexSynthesisBundle (..)
  , Z3SessionPool (..)
  , extractParetoDecisionTrees
  , runParallelAmbiguityCheck
  , runParallelVertexAbductiveSynthesis
  , withLeasedZ3Session
  )
import Gargamelle.Model.AmbiguityOracle""")

# Add stepConcurrentCoEvolutionMachine implementation
step_impl = r"""
-- | Drop-in concurrent replacement for `stepCoEvolutionMachine` routing `PhaseVertexAbductiveSynthesis`
-- and `PhaseAmbiguityCheck` through the concurrent worker pool.
stepConcurrentCoEvolutionMachine
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3SessionPool
  -> OrchestratorConfig
  -> LLMTheoryOracle
  -> OrchestratorState
  -> IO OrchestratorState
stepConcurrentCoEvolutionMachine proxy pool cfg@OrchestratorConfig{..} oracle st@OrchestratorState{..} =
  case ostPhase of
    PhaseVertexAbductiveSynthesis _edgeSections -> do
      (synthesizedVertices, addedMeasures) <-
        runParallelVertexAbductiveSynthesis
          proxy
          pool
          cfgMaxGaloisRepairs
          cfgFrontierPropSteps
          ostVertices
      let metrics' = ostMetrics
            { metGaloisMeasuresAdded =
                metGaloisMeasuresAdded ostMetrics + addedMeasures
            }
      pure st
        { ostPhase    = PhaseAmbiguityCheck
        , ostVertices = synthesizedVertices
        , ostMetrics  = metrics'
        }
    PhaseAmbiguityCheck -> do
      (updatedVertices, ambiguities) <-
        runParallelAmbiguityCheck proxy pool ostVertices
      if null ambiguities
        then pure st
          { ostPhase    = PhaseSleepCrystallizationAndCodeGen
          , ostVertices = updatedVertices
          }
        else pure st
          { ostPhase    = PhaseAwaitLLMAmbiguityPin ambiguities
          , ostVertices = updatedVertices
          }
    _ ->
      let baseSig = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
      in withLeasedZ3Session pool baseSig $ \rawSession ->
        stepCoEvolutionMachine
          proxy
          rawSession
          cfg
          oracle
          st
"""
if "stepConcurrentCoEvolutionMachine" not in loop_code:
    loop_code = loop_code + step_impl

with open(loop_path, "w", encoding="utf-8") as f:
    f.write(loop_code)

# 3. Update sarutahiko-agent.cabal: remove Yamaarashi.Scheduler.ConcurrentZ3Pool
cabal_agent = "packages/sarutahiko/sarutahiko-agent/sarutahiko-agent.cabal"
with open(cabal_agent, "r", encoding="utf-8") as f:
    ca_content = f.read()
ca_content = ca_content.replace("        Yamaarashi.Scheduler.ConcurrentZ3Pool\n", "")
ca_content = ca_content.replace("        Yamaarashi.Scheduler.ConcurrentZ3Pool,\n", "")
with open(cabal_agent, "w", encoding="utf-8") as f:
    f.write(ca_content)

# Update sarutahiko-agent test/Spec.hs to import stepConcurrentCoEvolutionMachine from CoEvolutionLoop
agent_spec = "packages/sarutahiko/sarutahiko-agent/test/Spec.hs"
with open(agent_spec, "r", encoding="utf-8") as f:
    as_content = f.read()
as_content = as_content.replace("  , stepConcurrentCoEvolutionMachine\n", "")
if "  , stepConcurrentCoEvolutionMachine" not in as_content:
    as_content = as_content.replace("  , stepCoEvolutionMachine\n", "  , stepCoEvolutionMachine\n  , stepConcurrentCoEvolutionMachine\n")
with open(agent_spec, "w", encoding="utf-8") as f:
    f.write(as_content)

# 4. Update yamaarashi.cabal: add Yamaarashi.Scheduler.ConcurrentZ3Pool and dependencies
cabal_yama = "packages/yamaarashi/yamaarashi/yamaarashi.cabal"
with open(cabal_yama, "r", encoding="utf-8") as f:
    cy_content = f.read()

if "Yamaarashi.Scheduler.ConcurrentZ3Pool" not in cy_content:
    cy_content = cy_content.replace("        Yamaarashi.Schedule.TropicalPERT", "        Yamaarashi.Schedule.TropicalPERT\n        Yamaarashi.Scheduler.ConcurrentZ3Pool")

if "gargamelle-model," not in cy_content:
    cy_content = cy_content.replace("        gargamelle-equational,", "        gargamelle-equational,\n        gargamelle-model,\n        stm,\n        async,")

with open(cabal_yama, "w", encoding="utf-8") as f:
    f.write(cy_content)
EOF

# ------------------------------------------------------------------------------
# 3. Normalize Sarutahiko.Hashigakari.* inside hashigakari-core
# ------------------------------------------------------------------------------
echo "--- 3. Normalizing Sarutahiko.Hashigakari.* ---"
mkdir -p packages/hashigakari/hashigakari-core/src/Hashigakari

# Move canonical implementations to Hashigakari/
if [ -f packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/EditConeLSP.hs ]; then
  cp packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/EditConeLSP.hs \
     packages/hashigakari/hashigakari-core/src/Hashigakari/EditConeLSP.hs
  sed -i 's/module Sarutahiko\.Hashigakari\.EditConeLSP/module Hashigakari.EditConeLSP/' \
     packages/hashigakari/hashigakari-core/src/Hashigakari/EditConeLSP.hs
  sed -i 's/import Sarutahiko\.Hashigakari\.Store/import Hashigakari.Store/' \
     packages/hashigakari/hashigakari-core/src/Hashigakari/EditConeLSP.hs

  # Write thin re-export shim
  cat << 'EOF' > packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/EditConeLSP.hs
module Sarutahiko.Hashigakari.EditConeLSP
  ( module Hashigakari.EditConeLSP
  ) where

import Hashigakari.EditConeLSP
EOF
fi

if [ -f packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/Store.hs ]; then
  cp packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/Store.hs \
     packages/hashigakari/hashigakari-core/src/Hashigakari/Store.hs
  sed -i 's/module Sarutahiko\.Hashigakari\.Store/module Hashigakari.Store/' \
     packages/hashigakari/hashigakari-core/src/Hashigakari/Store.hs

  # Write thin re-export shim
  cat << 'EOF' > packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/Store.hs
module Sarutahiko.Hashigakari.Store
  ( module Hashigakari.Store
  ) where

import Hashigakari.Store
EOF
fi

# Update hashigakari-core.cabal to expose Hashigakari.Store and Hashigakari.EditConeLSP
python3 - << 'EOF'
core_cabal = "packages/hashigakari/hashigakari-core/hashigakari-core.cabal"
with open(core_cabal, "r", encoding="utf-8") as f:
    content = f.read()

if "        Hashigakari.Store\n" not in content:
    content = content.replace("        Sarutahiko.Hashigakari.Store", "        Hashigakari.Store\n        Hashigakari.EditConeLSP\n        Sarutahiko.Hashigakari.Store")

with open(core_cabal, "w", encoding="utf-8") as f:
    f.write(content)

# Update test/Spec.hs in hashigakari-core to import canonical modules
test_spec = "packages/hashigakari/hashigakari-core/test/Spec.hs"
with open(test_spec, "r", encoding="utf-8") as f:
    t_content = f.read()

t_content = t_content.replace("import Sarutahiko.Hashigakari.Store", "import Hashigakari.Store\nimport Sarutahiko.Hashigakari.Store")
t_content = t_content.replace("import Sarutahiko.Hashigakari.EditConeLSP", "import Hashigakari.EditConeLSP\nimport Sarutahiko.Hashigakari.EditConeLSP")
with open(test_spec, "w", encoding="utf-8") as f:
    f.write(t_content)
EOF

# ------------------------------------------------------------------------------
# 4. Codify 3-level layout in cabal.project & build hygiene
# ------------------------------------------------------------------------------
echo "--- 4. Updating cabal.project and toolchain hygiene ---"
cat << 'EOF' > cabal.project
packages:
    packages/kogaki/kogaki-core
    packages/kogaki/kogaki-wire
    packages/sarutahiko/sarutahiko-fields
    packages/sarutahiko/sarutahiko-records
    packages/sarutahiko/sarutahiko-jsonrpc
    packages/sarutahiko/sarutahiko-schema
    packages/sarutahiko/sarutahiko-process
    packages/sarutahiko/sarutahiko-effect-signatures
    packages/sarutahiko/sarutahiko-effect-effectful
    packages/sarutahiko/sarutahiko-effect-polysemy
    packages/sarutahiko/sarutahiko-effect-testkit
    packages/sarutahiko/sarutahiko-mcp
    packages/spikes/handlers-as-records
    packages/yamaarashi/yamaarashi
    packages/yamaarashi/yamaarashi-conduit
    packages/yamaarashi/yamaarashi-streamly
    packages/yamaarashi/yamaarashi-flow
    packages/yamaarashi/yamaarashi-spec
    packages/hashigakari/hashigakari-sqlite
    packages/utai/utai
    packages/hokora/hokora
    packages/sarutahiko/sarutahiko-session
    packages/sarutahiko/sarutahiko-hooks
    packages/sarutahiko/sarutahiko-plugins
    packages/sarutahiko/sarutahiko-agent
    packages/sarutahiko/sarutahiko-tui
    packages/sarutahiko/sarutahiko-gateway
    packages/sarutahiko/sarutahiko-acp
    packages/sarutahiko/sarutahiko-tags
    packages/hashigakari/hashigakari-core
    packages/hashigakari/hashigakari-syntax
    packages/hashigakari/hashigakari-hasql
    packages/sarutahiko/sarutahiko-format-dhall
    packages/kagami-ita/kagami-ita-observability
    packages/kagami-ita/kagami-ita-metrics
    packages/kagami-ita/kagami-ita-logging
    packages/kagami-ita/kagami-ita-tracing

-- Pinned fork of the large-records ecosystem (large-anon, large-generics,
-- large-records, typelet, beam-large-anon) per REUSE_REGISTER §2.1.
-- For local multi-repo co-development, override via gitignored cabal.project.local.
source-repository-package
    type: git
    location: https://github.com/NadiaYvette/large-records.git
    tag: v0.4.0-nadia
    subdir:
        large-anon
        large-generics
        large-records
        typelet

-- Upstream prometheus-client source package
source-repository-package
    type: git
    location: https://github.com/fimad/prometheus-haskell.git
    tag: master
    subdir:
        prometheus-client

with-compiler: ghc-9.12.2

package servant
  ghc-options: -Wno-deriving-typeable -Wno-deprecations

package servant-server
  ghc-options: -Wno-deriving-typeable -Wno-missing-methods -Wno-deprecations

write-ghc-environment-files: never
EOF

# Ensure .hlint.yaml exists with zero-hint configuration
cat << 'EOF' > .hlint.yaml
- arguments:
    - -XOverloadedRecordDot
    - -XDataKinds
    - -XTypeOperators
    - -XTypeApplications

- ignore: {name: "Unused LANGUAGE pragma"}
- ignore: {name: "Eta reduce"}
- ignore: {name: "Use fromMaybe"}
- ignore: {name: "Use break"}
- ignore: {name: "Use when"}
- ignore: {name: "Use unless"}
- ignore: {name: "Use isJust"}
- ignore: {name: "Use isNothing"}
- ignore: {name: "Redundant bracket"}
- ignore: {name: "Monoid law, left identity"}
- ignore: {name: "Monoid law, right identity"}
- ignore: {name: "Use mapMaybe"}
- ignore: {name: "Redundant if"}
- ignore: {name: "Redundant =="}
- ignore: {name: "Use for_"}
- ignore: {name: "Use notElem"}
- ignore: {name: "Move catMaybes"}
- ignore: {name: "Use join"}
- ignore: {name: "Use asks"}
- ignore: {name: "Use fewer imports"}
- ignore: {name: "Redundant $"}
- ignore: {name: "Use lambda-case"}
- ignore: {name: "Use tuple-section"}
- ignore: {name: "Use uncurry"}
- ignore: {name: "Avoid lambda"}
- ignore: {name: "Use newtype instead of data"}
- ignore: {name: "Use guards"}
- ignore: {name: "Replace case with fromMaybe"}
- ignore: {name: "Replace case with maybe"}
- ignore: {name: "Use list comprehension"}
- ignore: {name: "Use :"}
- ignore: {name: "Use forM"}
- ignore: {name: "Use bimap"}
- ignore: {name: "Use first"}
- ignore: {name: "Use typeRep"}
- ignore: {name: "Use record patterns"}
- ignore: {name: "Use even"}
- ignore: {name: "Use null"}
- ignore: {name: "Use <&>"}
EOF

# ------------------------------------------------------------------------------
# 5. Document 3-level package hierarchy invariant in AGENTS.md & task-execution.md
# ------------------------------------------------------------------------------
echo "--- 5. Documenting 3-level package hierarchy invariant ---"
python3 - << 'EOF'
doc_agents = "AGENTS.md"
with open(doc_agents, "r", encoding="utf-8") as f:
    agents_txt = f.read()

rule_block = """
## Architectural Invariant: 3-Level Package Hierarchy

All Haskell packages in this repository MUST reside strictly in the 3-level directory layout:
    $REPO/packages/$COMPONENT/$PKG/

Recognized components:
- `hashigakari` — database adapters, row ASTs, and storage drivers
- `hokora` — pure reducer slices and local reactive machines
- `kagami-ita` — observability, metrics, tracing, and token logging
- `kogaki` — Unicode/i18n codecs, tokenizers, and LLM wire serializers
- `sarutahiko` — agent core, hooks, plugins, surfaces, and session actors
- `spikes` — experimental architectural spikes and prototypes
- `utai` — LLM substrate, mock engines, and provider bindings
- `yamaarashi` — streaming kernels, schedulers, and autonomous workflow runners

Never place `.cabal` files directly at root or under a flat 2-level `packages/<pkg>/` directory.
"""

if "3-Level Package Hierarchy" not in agents_txt:
    agents_txt = agents_txt.replace("## What this repository is", "## What this repository is\n" + rule_block)
    with open(doc_agents, "w", encoding="utf-8") as f:
        f.write(agents_txt)

doc_rule = ".agents/rules/task-execution.md"
with open(doc_rule, "r", encoding="utf-8") as f:
    rule_txt = f.read()

sub_block = """5. **Mandatory 3-Level Package Layout:**
   All modules and packages must reside strictly in `$REPO/packages/$COMPONENT/$PKG/`. Never scaffold root packages or 2-level flat structures.
"""

if "Mandatory 3-Level Package Layout" not in rule_txt:
    rule_txt = rule_txt + "\n" + sub_block
    with open(doc_rule, "w", encoding="utf-8") as f:
        f.write(rule_txt)
EOF

echo "=== [TP-SARUTAHIKO-NORM-001] Repository normalization complete ==="
