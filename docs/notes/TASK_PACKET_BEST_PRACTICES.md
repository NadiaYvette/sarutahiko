# Task Packet Best Practices

This document captures guidance for writing effective, achievable task packets in the sarutahiko project, based on lessons learned from the yamaarashi‑group1 effort.

## Core Principle: Verify the Foundation First

Before investing effort in substantial implementation, a task packet should contain **early, concrete verification steps** that prove the toolchain, dependencies, and minimal buildable skeleton work.  If these checks fail, the packet is blocked and the user must resolve the underlying issue before proceeding.

## Recommended Structure

1. **Skeleton Creation Step**  
   - Create the minimal cabal file and source file(s) that define the module(s) but contain no functional code (e.g., `module X where`).  
   - Purpose: establish the package layout and Cabal metadata.

2. **Build‑Check Gate**  
   - Run `cabal v2-build <package>` (or `cabal v2-build all-local-packages`) immediately after skeleton creation.  
   - If this fails, the packet is considered **blocked**; the user must fix the toolchain/dependency problem before moving on.

3. **Dependency Validation (Optional but Helpful)**  
   - Run `cabal v2-install --only-dependencies <package>` or `cabal v2-list-bin` to confirm that dependency resolution succeeds.  
   - Surface any version conflicts explicitly.

4. **Smoke‑Test Executable**  
   - Add a trivial executable (or test suite) that does nothing more than print a success message.  
   - Build and run it (`cabal v2-run <package>:exe:<name>` or `cabal v2-test`).  
   - A passing smoke test confirms that the package database, layout, and toolchain are functional.

5. **Incremental Implementation with Verification**  
   - Implement one small piece (e.g., a single combinator, a single effect signature, a single adapter function).  
   - Add a corresponding unit‑test or property‑test that exercises that piece.  
   - Only proceed to the next piece once the build and its tests succeed.

6. **Document the Exact Working Command**  
   - Record the precise invocation that succeeded, including:  
     - `PATH` adjustments (e.g., `/home/nyc/.ghcup/bin:$PATH`)  
     - GHC version used (`ghc --version`)  
     - Any `cabal configure` flags or `cabal.project.local` constraints  
     - Environment variables that affect the build  

   Future contributors can copy‑paste this command to reproduce a known‑good baseline.

7. **Leverage Existing Verification Scripts**  
   - If the repo provides a CI or validation script (e.g., `ci/build.sh`, `script/validate`), invoke it as part of the packet’s verification steps.  
   - Reusing a known‑good script reduces the chance of overlooking flags or environment variables.

## Example Packet Excerpt

```yaml
steps:
  - id: create-skeleton
    description: |
      Create packages/yamaarashi/{yamaarashi.cabal,src/Yamaarashi.hs}
      with a minimal module exporting nothing.
    command: |
      mkdir -p packages/yamaarashi/src
      cat > packages/yamaarashi/yamaarashi.cabal <<'EOF'
      name: yamaarashi
      version: 0.1.0.0
      synopsis: Yamaarashi streaming kernel
      license: MIT
      build-type: Simple
      cabal-version: >=1.10
      library
        exposed-modules: Yamaarashi
        hs-source-dirs: src
        default-language: Haskell2010
      EOF
      echo "module Yamaarashi where" > packages/yamaarashi/src/Yamaarashi.hs

  - id: verify-build
    description: |
      Attempt to build the kernel; fail fast if the toolchain is broken.
    command: |
      cd /home/nyc/src/sarutahiko/packages/yamaarashi
      PATH=/home/nyc/.ghcup/bin:$PATH cabal v2-build

  - id: smoke-test
    description: |
      Build and run a trivial executable to confirm the package database works.
    command: |
      mkdir -p packages/yamaarashi/app
      echo "main = putStrLn \"OK\"" > packages/yamaarashi/app/Main.hs
      # (adjust cabal to add an executable stanza if needed, or use a test suite)
      cd /home/nyc/src/sarutahiko/packages/yamaarashi
      PATH=/home/nyc/.ghcup/bin:$PATH cabal v2-run yamaarashi:exe:smoke  # or test
```

## Why This Helps

- **Early Detection**: Toolchain or dependency issues surface within the first few minutes, not after hours of coding.
- **Clear Blockage Reason**: When a packet is marked “judged unachievable,” the cause is explicit (e.g., “cabal v2-build failed with exit 1”), enabling targeted remediation.
- **Iterative Confidence**: Each small, verified step builds confidence that the foundation is solid before moving on to larger pieces.
- **Reusability**: The same verification pattern can be copied into future packets, creating a consistent workflow across the team.

By following this pattern, task packets remain **tractable**, **verifiable**, and **aligned with the project’s emphasis on measurable progress**.
