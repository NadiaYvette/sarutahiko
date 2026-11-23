#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-SARUTAHIKO-001] Executing task implementation ==="

# 1. Ensure go.mod exists at repo root
if [ ! -f go.mod ]; then
  cat << 'EOF' > go.mod
module sarutahiko

go 1.24
EOF
  echo "Created go.mod"
fi

# 2. Extract and write nadiverse-coverage.go with //go:build ignore
python3 - << 'EOF'
with open("/tmp/nadiverse-coverage-seed.go") as f:
    cov_content = f.read()

with open("scripts/tools/nadiverse-coverage.go", "w") as f:
    f.write("//go:build ignore\n" + cov_content)
print("Wrote scripts/tools/nadiverse-coverage.go")
EOF

# 3. Update hls-autoheal.go
python3 - << 'EOF'
with open("scripts/tools/hls-autoheal.go") as f:
    orig = f.read()

edit_def = """type Edit struct {
	File        string
	LineNum     int // 1-based
	ColNum      int // 1-based
	OldText     string
	NewText     string
	Action      string // "replace", "delete", "insert_pragma"
	Description string
}"""

orig = orig.replace("""type Edit struct {
	File        string
	LineNum     int // 1-based
	OldText     string
	NewText     string
	Action      string // "replace", "delete", "insert_pragma"
	Description string
}""", edit_def)

ghc_38856_code = """
	// 1b. Redundant individual import symbol: GHC-38856
	// Example:
	// packages/smirk/src/Smirk/Core/Budget.hs:68:18: warning: [GHC-38856] [-Wunused-imports]
	//     The import of ‘readIORef’ from module ‘Data.IORef’ is redundant
	reUnusedSym := regexp.MustCompile(`(?m)^([^\\s:]+\\.hs):(\\d+):(\\d+):\\s*(?:warning|error):\\s*\\[GHC-38856\\]\\s*\\[-Wunused-imports\\][\\s\\S]*?The import of ‘([^’]+)’(?:\\s*from module ‘([^’]+)’)?(?:\\s*is redundant)`)
	for _, match := range reUnusedSym.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		col, _ := strconv.Atoi(match[3])
		sym := match[4]
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			ColNum:      col,
			Action:      "trim_import_symbol",
			NewText:     sym,
			Description: fmt.Sprintf("Remove redundant import symbol ‘%s’ (GHC-38856)", sym),
		})
	}
"""

ghc_83475_code = """
	// 6. Unused record wildcard: GHC-83475
	// Example:
	// packages/smirk/src/Smirk/Sheaf/Parallel.hs:80:24: warning: [GHC-83475] [-Wunused-record-wildcards]
	//     No variables bound in the record pattern are used
	//     Suggested fix: Remove ‘..’ or use a wild card pattern
	reUnusedWildcard := regexp.MustCompile(`(?m)^([^\\s:]+\\.hs):(\\d+):(\\d+):\\s*(?:warning|error):\\s*\\[GHC-83475\\]\\s*\\[-Wunused-record-wildcards\\]`)
	for _, match := range reUnusedWildcard.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		col, _ := strconv.Atoi(match[3])
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			ColNum:      col,
			Action:      "replace_wildcard",
			Description: fmt.Sprintf("Replace unused record wildcard {..} with {} (GHC-83475) on line %d", line),
		})
	}
"""

target_66111 = 'Description: fmt.Sprintf("Remove redundant import of %s (GHC-66111)", mod),\n\t\t})\n\t}'
orig = orig.replace(target_66111, target_66111 + "\n" + ghc_38856_code)

target_total = 'totalApplied := 0'
orig = orig.replace(target_total, ghc_83475_code + "\n\t" + target_total)

target_case = """\t\tcase "delete_or_trim_import":
			line := lines[idx]
			if strings.HasPrefix(strings.TrimSpace(line), "import ") {
				fmt.Printf("  [+] %s:%d: %s\\n", filePath, edit.LineNum, edit.Description)
				linesToDelete[idx] = true
				appliedCount++
				modified = true
			}"""

new_cases = """\t\tcase "delete_or_trim_import":
			line := lines[idx]
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "import ") {
				fmt.Printf("  [+] %s:%d: %s\\n", filePath, edit.LineNum, edit.Description)
				linesToDelete[idx] = true
				depth := 0
				sawParen := false
				for _, ch := range line {
					if ch == '(' {
						depth++
						sawParen = true
					} else if ch == ')' {
						depth--
					}
				}
				if sawParen && depth > 0 {
					for j := idx + 1; j < len(lines); j++ {
						linesToDelete[j] = true
						for _, ch := range lines[j] {
							if ch == '(' {
								depth++
							} else if ch == ')' {
								depth--
							}
						}
						if depth <= 0 {
							break
						}
					}
				} else if !sawParen {
					// Check if next line continues the import
					for j := idx + 1; j < len(lines); j++ {
						nxtTrim := strings.TrimSpace(lines[j])
						if nxtTrim == "" || strings.HasPrefix(nxtTrim, "import ") || (!strings.HasPrefix(lines[j], " ") && !strings.HasPrefix(lines[j], "\\t")) {
							break
						}
						for _, ch := range lines[j] {
							if ch == '(' {
								depth++
								sawParen = true
							} else if ch == ')' {
								depth--
							}
						}
						linesToDelete[j] = true
						if sawParen && depth <= 0 {
							break
						}
					}
				}
				appliedCount++
				modified = true
			}

		case "trim_import_symbol":
			sym := strings.TrimSpace(edit.NewText)
			symBase := strings.TrimSpace(strings.TrimSuffix(strings.TrimSuffix(sym, "(..)"), " "))
			symPattern := `\\b` + regexp.QuoteMeta(symBase) + `(?:\\s*\\(\\.\\.\\))?`

			importStart := idx
			for importStart > 0 && !strings.HasPrefix(strings.TrimSpace(lines[importStart]), "import ") {
				importStart--
			}
			importEnd := idx
			depth := 0
			sawParen := false
			for j := importStart; j < len(lines); j++ {
				for _, ch := range lines[j] {
					if ch == '(' {
						depth++
						sawParen = true
					} else if ch == ')' {
						depth--
					}
				}
				importEnd = j
				if sawParen && depth <= 0 {
					break
				}
				if !sawParen && j > importStart {
					nxtTrim := strings.TrimSpace(lines[j])
					if nxtTrim == "" || (!strings.HasPrefix(lines[j], " ") && !strings.HasPrefix(lines[j], "\\t")) {
						importEnd = j - 1
						break
					}
				}
			}

			var importSlice []string
			for k := importStart; k <= importEnd; k++ {
				importSlice = append(importSlice, lines[k])
			}
			fullImport := strings.Join(importSlice, "\\n")

			reOnly := regexp.MustCompile(`\\(\\s*` + symPattern + `\\s*\\)`)
			if reOnly.MatchString(fullImport) {
				fmt.Printf("  [+] %s:%d: %s (only symbol: deleting entire import)\\n", filePath, edit.LineNum, edit.Description)
				for k := importStart; k <= importEnd; k++ {
					linesToDelete[k] = true
				}
				appliedCount++
				modified = true
			} else {
				curLine := lines[idx]
				reTrailing := regexp.MustCompile(symPattern + `\\s*,\\s*`)
				reLeading := regexp.MustCompile(`,\\s*` + symPattern)
				reLineOnly := regexp.MustCompile(`^\\s*(?:,\\s*)?` + symPattern + `\\s*(?:,\\s*)?$`)

				if reLineOnly.MatchString(curLine) && importStart != importEnd {
					fmt.Printf("  [+] %s:%d: %s (removing symbol line)\\n", filePath, edit.LineNum, edit.Description)
					linesToDelete[idx] = true
					appliedCount++
					modified = true
				} else if reTrailing.MatchString(curLine) {
					fmt.Printf("  [+] %s:%d: %s (trimming trailing comma)\\n", filePath, edit.LineNum, edit.Description)
					lines[idx] = reTrailing.ReplaceAllString(curLine, "")
					appliedCount++
					modified = true
				} else if reLeading.MatchString(curLine) {
					fmt.Printf("  [+] %s:%d: %s (trimming leading comma)\\n", filePath, edit.LineNum, edit.Description)
					lines[idx] = reLeading.ReplaceAllString(curLine, "")
					appliedCount++
					modified = true
				}
			}

		case "replace_wildcard":
			line := lines[idx]
			reWC := regexp.MustCompile(`\\{\\s*\\.\\.\\s*\\}`)
			if reWC.MatchString(line) {
				fmt.Printf("  [+] %s:%d: %s\\n", filePath, edit.LineNum, edit.Description)
				lines[idx] = reWC.ReplaceAllString(line, "{}")
				appliedCount++
				modified = true
			}"""

orig = orig.replace(target_case, new_cases)

with open("scripts/tools/hls-autoheal.go", "w") as f:
    f.write(orig)

print("Updated scripts/tools/hls-autoheal.go")
EOF

# 4. Write hls_autoheal_test.go
cat << 'EOF' > scripts/tools/hls_autoheal_test.go
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runAutoHealOnFile(t *testing.T, initialContent, compilerLog string) string {
	t.Helper()
	dir := t.TempDir()
	filePath := filepath.Join(dir, "Test.hs")
	if err := os.WriteFile(filePath, []byte(initialContent), 0644); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	logReplaced := strings.ReplaceAll(compilerLog, "Test.hs", filePath)
	applied := autoHealLog(logReplaced, false)
	if applied == 0 {
		t.Fatalf("expected auto-heal edits to be applied, got 0")
	}

	resultBytes, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("failed to read result file: %v", err)
	}
	return string(resultBytes)
}

func TestGHC66111SingleLine(t *testing.T) {
	initial := `module Test where

import Control.Applicative
import Data.Text (Text)

foo :: Text
foo = undefined
`
	log := `Test.hs:3:1: warning: [GHC-66111] [-Wunused-imports]
    The import of ‘Control.Applicative’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	if strings.Contains(res, "Control.Applicative") {
		t.Fatalf("expected Control.Applicative to be removed, got:\n%s", res)
	}
	if !strings.Contains(res, "import Data.Text (Text)") {
		t.Fatalf("expected Data.Text to remain, got:\n%s", res)
	}
}

func TestGHC66111MultiLine(t *testing.T) {
	initial := `module Test where

import Data.List
  ( foldl'
  , intercalate
  )
import Data.Text (Text)

foo :: Text
foo = undefined
`
	log := `Test.hs:3:1: warning: [GHC-66111] [-Wunused-imports]
    The import of ‘Data.List’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	if strings.Contains(res, "Data.List") || strings.Contains(res, "foldl'") || strings.Contains(res, "intercalate") {
		t.Fatalf("expected entire multi-line Data.List import to be removed, got:\n%s", res)
	}
	if !strings.Contains(res, "import Data.Text (Text)") {
		t.Fatalf("expected Data.Text to remain, got:\n%s", res)
	}
}

func TestGHC38856FirstItem(t *testing.T) {
	initial := `module Test where

import Polytropos.Core (Pair(..), Rep(..), RowRep(..))

foo :: Int
foo = 42
`
	log := `Test.hs:3:25: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘Pair(..)’ from module ‘Polytropos.Core’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "import Polytropos.Core (Rep(..), RowRep(..))"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}

func TestGHC38856MiddleItem(t *testing.T) {
	initial := `module Test where

import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)

foo :: Int
foo = 42
`
	log := `Test.hs:3:48: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘readIORef’ from module ‘Data.IORef’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "import Data.IORef (atomicModifyIORef', newIORef, writeIORef)"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}

func TestGHC38856LastItem(t *testing.T) {
	initial := `module Test where

import GHC.TypeLits (Symbol, KnownSymbol)

foo :: Int
foo = 42
`
	log := `Test.hs:3:30: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘KnownSymbol’ from module ‘GHC.TypeLits’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "import GHC.TypeLits (Symbol)"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}

func TestGHC38856OnlyItem(t *testing.T) {
	initial := `module Test where

import Smirk.Core.Types (Fuel (..))
import Data.Text (Text)

foo :: Text
foo = undefined
`
	log := `Test.hs:3:26: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘Fuel(..)’ from module ‘Smirk.Core.Types’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	if strings.Contains(res, "Smirk.Core.Types") {
		t.Fatalf("expected whole import to be removed when only symbol is redundant, got:\n%s", res)
	}
	if !strings.Contains(res, "import Data.Text (Text)") {
		t.Fatalf("expected Data.Text to remain, got:\n%s", res)
	}
}

func TestGHC83475RecordWildcard(t *testing.T) {
	initial := `module Test where

buildChunkStalk :: Regex -> Int
buildChunkStalk Regex{..} = 0
`
	log := `Test.hs:4:23: warning: [GHC-83475] [-Wunused-record-wildcards]
    No variables bound in the record pattern are used
    Suggested fix: Remove ‘..’ or use a wild card pattern
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "buildChunkStalk Regex{} = 0"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}
EOF
echo "Wrote scripts/tools/hls_autoheal_test.go"

echo "=== [TP-SARUTAHIKO-001] Task implementation complete ==="
