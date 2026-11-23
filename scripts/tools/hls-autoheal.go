// #!/usr/bin/env yaegi
// hls-autoheal: Automated GHC / HLS diagnostics auto-healer for agentic Haskell workflows.
// Repairs common mechanical failures without burning LLM turn context:
//   - Unused imports (GHC-66111 / -Wunused-imports)
//   - Deprecated pattern namespace specifier (GHC-68383 / -Wpattern-namespace-specifier)
//   - Missing LANGUAGE pragmas (PatternSynonyms, OverloadedStrings, GHC2024, etc.)
//   - Unused LANGUAGE pragmas (HLint / GHC)
//   - Common HLint micro-refactorings (Use fromMaybe, etc.)

package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	flagLog       = flag.String("log", "", "Path to build or compiler log file to parse")
	flagStdin     = flag.Bool("stdin", false, "Read compiler/HLS diagnostics from standard input")
	flagHLS       = flag.Bool("hls", false, "Invoke haskell-language-server typecheck on targets")
	flagBuild     = flag.String("build", "", "Run specified build command (e.g. 'cabal build') and autoheal")
	flagDryRun    = flag.Bool("dry-run", false, "Print planned edits without modifying files on disk")
	flagVerbose   = flag.Bool("verbose", false, "Enable verbose logging")
	flagMaxCycles = flag.Int("max-cycles", 3, "Maximum heal-and-build iteration cycles")
)

type Edit struct {
	File        string
	LineNum     int // 1-based
	ColNum      int // 1-based
	OldText     string
	NewText     string
	Action      string // "replace", "delete", "insert_pragma"
	Description string
}

func main() {
	flag.Parse()

	if *flagBuild != "" {
		runBuildLoop(*flagBuild, *flagMaxCycles, *flagDryRun)
		return
	}

	var logData string

	if *flagLog != "" {
		data, err := os.ReadFile(*flagLog)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading log file %s: %v\n", *flagLog, err)
			os.Exit(1)
		}
		logData = string(data)
	} else if *flagStdin {
		data, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading stdin: %v\n", err)
			os.Exit(1)
		}
		logData = string(data)
	} else if *flagHLS {
		targets := flag.Args()
		if len(targets) == 0 {
			targets = []string{"."}
		}
		logData = runHLSTypecheck(targets)
	} else {
		// If files passed, check if any log or targets
		targets := flag.Args()
		if len(targets) > 0 {
			logData = runHLSTypecheck(targets)
		} else {
			flag.Usage()
			os.Exit(1)
		}
	}

	applied := autoHealLog(logData, *flagDryRun)
	fmt.Printf("=== [hls-autoheal] Applied %d automated repairs ===\n", applied)
}

func runHLSTypecheck(targets []string) string {
	hlsBin := "haskell-language-server"
	if custom := os.Getenv("HLS_BIN"); custom != "" {
		hlsBin = custom
	} else if path, err := exec.LookPath("haskell-language-server"); err == nil {
		hlsBin = path
	} else if _, err := os.Stat("/home/nyc/.local/bin/haskell-language-server"); err == nil {
		hlsBin = "/home/nyc/.local/bin/haskell-language-server"
	}

	args := append([]string{"typecheck"}, targets...)
	fmt.Printf("=== [hls-autoheal] Running %s %s ===\n", hlsBin, strings.Join(args, " "))
	cmd := exec.Command(hlsBin, args...)
	out, _ := cmd.CombinedOutput()
	return string(out)
}

func runBuildLoop(buildCmd string, maxCycles int, dryRun bool) {
	parts := strings.Fields(buildCmd)
	if len(parts) == 0 {
		fmt.Fprintf(os.Stderr, "Empty build command\n")
		os.Exit(1)
	}

	for cycle := 1; cycle <= maxCycles; cycle++ {
		fmt.Printf("=== [hls-autoheal] Build Cycle %d of %d: '%s' ===\n", cycle, maxCycles, buildCmd)
		cmd := exec.Command(parts[0], parts[1:]...)
		out, err := cmd.CombinedOutput()
		logStr := string(out)

		if err == nil {
			fmt.Println("=== [hls-autoheal] Build SUCCEEDED cleanly! ===")
			return
		}

		fmt.Printf("=== [hls-autoheal] Build failed. Scanning diagnostics for auto-healable patterns... ===\n")
		applied := autoHealLog(logStr, dryRun)
		if applied == 0 {
			fmt.Printf("=== [hls-autoheal] No mechanical auto-heal patterns matched in cycle %d ===\n", cycle)
			fmt.Println(logStr)
			os.Exit(1)
		}
		fmt.Printf("=== [hls-autoheal] Applied %d fixes. Re-testing build... ===\n", applied)
	}

	fmt.Fprintf(os.Stderr, "=== [hls-autoheal] Reached maximum cycles (%d) without resolution ===\n", maxCycles)
	os.Exit(1)
}

func autoHealLog(logText string, dryRun bool) int {
	editsByFile := make(map[string][]Edit)

	// 1. Redundant full imports: GHC-66111
	// Example:
	// packages/smirk/src/Smirk/Core/Parser.hs:54:1: warning: [GHC-66111] [-Wunused-imports]
	//     The import of ‘Control.Applicative’ is redundant
	reUnusedImport := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):(\d+):\s*(?:warning|error):\s*\[GHC-66111\]\s*\[-Wunused-imports\][\s\S]*?The (?:qualified )?import of ‘([^’]+)’ is redundant`)
	for _, match := range reUnusedImport.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		mod := match[4]
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			Action:      "delete_or_trim_import",
			Description: fmt.Sprintf("Remove redundant import of %s (GHC-66111)", mod),
		})
	}

	// 1b. Redundant individual import symbol: GHC-38856
	// Example:
	// packages/smirk/src/Smirk/Core/Budget.hs:68:18: warning: [GHC-38856] [-Wunused-imports]
	//     The import of ‘readIORef’ from module ‘Data.IORef’ is redundant
	reUnusedSym := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):(\d+):\s*(?:warning|error):\s*\[GHC-38856\]\s*\[-Wunused-imports\][\s\S]*?The import of ‘([^’]+)’(?:\s*from module ‘([^’]+)’)?(?:\s*is redundant)`)
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


	// 2. Deprecated pattern namespace specifier: GHC-68383
	// Standard GHC format:
	// test/ParserSpec.hs:9:42: warning: [GHC-68383] [-Wpattern-namespace-specifier]
	//     The ‘pattern’ namespace specifier is deprecated.
	//     Suggested fix: Use the ‘data’ keyword instead.
	reDeprecatedPattern := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):(\d+):\s*(?:warning|error):\s*\[GHC-68383\][\s\S]*?Use the ‘data’ keyword instead`)
	for _, match := range reDeprecatedPattern.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			Action:      "pattern_to_data",
			Description: "Replace deprecated 'pattern' keyword with 'data' (GHC-68383)",
		})
	}

	// HLS output format for GHC-68383:
	// File:     /path/to/File.hs
	// Range:    81:5-81:12
	// Code:     GHC-68383
	reHLSPattern := regexp.MustCompile(`(?m)File:\s+([^\s]+\.hs)[\s\S]*?Range:\s+(\d+):\d+-\d+:\d+[\s\S]*?Code:\s+GHC-68383`)
	for _, match := range reHLSPattern.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			Action:      "pattern_to_data",
			Description: "Replace deprecated 'pattern' keyword with 'data' (HLS/GHC-68383)",
		})
	}

	// 3. Missing LANGUAGE pragmas suggested by GHC:
	// Perhaps you intended to use PatternSynonyms
	// Use -XOverloadedStrings or similar
	reMissingPragma := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):(\d+):\s*error:[\s\S]*?(?:Perhaps you intended to use|Use -X)([A-Za-z0-9]+)`)
	for _, match := range reMissingPragma.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		pragma := match[4]
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			Action:      "insert_pragma",
			NewText:     pragma,
			Description: fmt.Sprintf("Insert missing pragma {-# LANGUAGE %s #-}", pragma),
		})
	}

	// 4. HLint / GHC unused LANGUAGE pragma:
	// Warning: Unused LANGUAGE pragma
	// Found:
	//   {-# LANGUAGE TypeApplications #-}
	// Perhaps you should remove it.
	reUnusedPragma := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):[^\n]*Unused LANGUAGE pragma[\s\S]*?\{-#\s*LANGUAGE\s+([A-Za-z0-9]+)\s*#-\}`)
	for _, match := range reUnusedPragma.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		pragma := match[3]
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			Action:      "delete_line",
			Description: fmt.Sprintf("Remove unused pragma {-# LANGUAGE %s #-}", pragma),
		})
	}

	// 5. HLint Use fromMaybe:
	// Warning: Use fromMaybe
	// Found:
	//   maybe 0 id
	// Perhaps:
	//   Data.Maybe.fromMaybe 0
	reFromMaybe := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):[^\n]*Use fromMaybe[\s\S]*?Found:\s*\n\s*maybe\s+([^\s\n]+)\s+id`)
	for _, match := range reFromMaybe.FindAllStringSubmatch(logText, -1) {
		file := match[1]
		line, _ := strconv.Atoi(match[2])
		defVal := match[3]
		editsByFile[file] = append(editsByFile[file], Edit{
			File:        file,
			LineNum:     line,
			Action:      "use_from_maybe",
			NewText:     defVal,
			Description: fmt.Sprintf("Replace 'maybe %s id' with 'fromMaybe %s'", defVal, defVal),
		})
	}

	
	// 6. Unused record wildcard: GHC-83475
	// Example:
	// packages/smirk/src/Smirk/Sheaf/Parallel.hs:80:24: warning: [GHC-83475] [-Wunused-record-wildcards]
	//     No variables bound in the record pattern are used
	//     Suggested fix: Remove ‘..’ or use a wild card pattern
	reUnusedWildcard := regexp.MustCompile(`(?m)^([^\s:]+\.hs):(\d+):(\d+):\s*(?:warning|error):\s*\[GHC-83475\]\s*\[-Wunused-record-wildcards\]`)
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

	totalApplied := 0
	for file, edits := range editsByFile {
		applied := applyFileEdits(file, edits, dryRun)
		totalApplied += applied
	}

	return totalApplied
}

func applyFileEdits(filePath string, edits []Edit, dryRun bool) int {
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		// Try resolving relative to git root or current dir
		if abs, err := filepath.Abs(filePath); err == nil {
			filePath = abs
		}
	}

	contentBytes, err := os.ReadFile(filePath)
	if err != nil {
		fmt.Printf("  [!] Skipping unreadable file: %s (%v)\n", filePath, err)
		return 0
	}

	lines := strings.Split(string(contentBytes), "\n")
	modified := false
	appliedCount := 0

	// Process insertions first (e.g. pragmas)
	for _, edit := range edits {
		if edit.Action == "insert_pragma" {
			pragmaDirective := fmt.Sprintf("{-# LANGUAGE %s #-}", edit.NewText)
			hasPragma := false
			insertIdx := 0

			for i, line := range lines {
				if strings.Contains(line, edit.NewText) && strings.Contains(line, "LANGUAGE") {
					hasPragma = true
					break
				}
				if strings.HasPrefix(strings.TrimSpace(line), "{-# LANGUAGE") {
					insertIdx = i + 1
				}
			}

			if !hasPragma {
				fmt.Printf("  [+] %s: %s\n", filePath, edit.Description)
				if !dryRun {
					newLines := make([]string, 0, len(lines)+1)
					newLines = append(newLines, lines[:insertIdx]...)
					newLines = append(newLines, pragmaDirective)
					newLines = append(newLines, lines[insertIdx:]...)
					lines = newLines
					modified = true
					appliedCount++
				}
			}
		}
	}

	// Process line modifications from highest line number to lowest to avoid index shifts
	// Sort or deduplicate line edits
	linesToDelete := make(map[int]bool)

	for _, edit := range edits {
		idx := edit.LineNum - 1
		if idx < 0 || idx >= len(lines) {
			continue
		}

		switch edit.Action {
		case "delete_line":
			fmt.Printf("  [+] %s:%d: %s\n", filePath, edit.LineNum, edit.Description)
			linesToDelete[idx] = true
			appliedCount++
			modified = true

		case "delete_or_trim_import":
			line := lines[idx]
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "import ") {
				fmt.Printf("  [+] %s:%d: %s\n", filePath, edit.LineNum, edit.Description)
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
						if nxtTrim == "" || strings.HasPrefix(nxtTrim, "import ") || (!strings.HasPrefix(lines[j], " ") && !strings.HasPrefix(lines[j], "\t")) {
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
			symPattern := `\b` + regexp.QuoteMeta(symBase) + `(?:\s*\(\.\.\))?`

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
					if nxtTrim == "" || (!strings.HasPrefix(lines[j], " ") && !strings.HasPrefix(lines[j], "\t")) {
						importEnd = j - 1
						break
					}
				}
			}

			var importSlice []string
			for k := importStart; k <= importEnd; k++ {
				importSlice = append(importSlice, lines[k])
			}
			fullImport := strings.Join(importSlice, "\n")

			reOnly := regexp.MustCompile(`\(\s*` + symPattern + `\s*\)`)
			if reOnly.MatchString(fullImport) {
				fmt.Printf("  [+] %s:%d: %s (only symbol: deleting entire import)\n", filePath, edit.LineNum, edit.Description)
				for k := importStart; k <= importEnd; k++ {
					linesToDelete[k] = true
				}
				appliedCount++
				modified = true
			} else {
				curLine := lines[idx]
				reTrailing := regexp.MustCompile(symPattern + `\s*,\s*`)
				reLeading := regexp.MustCompile(`,\s*` + symPattern)
				reLineOnly := regexp.MustCompile(`^\s*(?:,\s*)?` + symPattern + `\s*(?:,\s*)?$`)

				if reLineOnly.MatchString(curLine) && importStart != importEnd {
					fmt.Printf("  [+] %s:%d: %s (removing symbol line)\n", filePath, edit.LineNum, edit.Description)
					linesToDelete[idx] = true
					appliedCount++
					modified = true
				} else if reTrailing.MatchString(curLine) {
					fmt.Printf("  [+] %s:%d: %s (trimming trailing comma)\n", filePath, edit.LineNum, edit.Description)
					lines[idx] = reTrailing.ReplaceAllString(curLine, "")
					appliedCount++
					modified = true
				} else if reLeading.MatchString(curLine) {
					fmt.Printf("  [+] %s:%d: %s (trimming leading comma)\n", filePath, edit.LineNum, edit.Description)
					lines[idx] = reLeading.ReplaceAllString(curLine, "")
					appliedCount++
					modified = true
				}
			}

		case "replace_wildcard":
			line := lines[idx]
			reWC := regexp.MustCompile(`\{\s*\.\.\s*\}`)
			if reWC.MatchString(line) {
				fmt.Printf("  [+] %s:%d: %s\n", filePath, edit.LineNum, edit.Description)
				lines[idx] = reWC.ReplaceAllString(line, "{}")
				appliedCount++
				modified = true
			}

		case "pattern_to_data":
			line := lines[idx]
			if strings.Contains(line, "pattern ") {
				fmt.Printf("  [+] %s:%d: %s\n", filePath, edit.LineNum, edit.Description)
				lines[idx] = strings.ReplaceAll(line, "pattern ", "data ")
				appliedCount++
				modified = true
			}

		case "use_from_maybe":
			line := lines[idx]
			targetStr := fmt.Sprintf("maybe %s id", edit.NewText)
			replaceStr := fmt.Sprintf("fromMaybe %s", edit.NewText)
			if strings.Contains(line, targetStr) {
				fmt.Printf("  [+] %s:%d: %s\n", filePath, edit.LineNum, edit.Description)
				lines[idx] = strings.Replace(line, targetStr, replaceStr, 1)
				// Ensure Data.Maybe (fromMaybe) is imported
				hasImport := false
				importInsertIdx := 0
				for i, l := range lines {
					if strings.Contains(l, "Data.Maybe") {
						hasImport = true
						break
					}
					if strings.HasPrefix(strings.TrimSpace(l), "import ") {
						importInsertIdx = i + 1
					}
				}
				if !hasImport && importInsertIdx > 0 {
					newLines := make([]string, 0, len(lines)+1)
					newLines = append(newLines, lines[:importInsertIdx]...)
					newLines = append(newLines, "import Data.Maybe (fromMaybe)")
					newLines = append(newLines, lines[importInsertIdx:]...)
					lines = newLines
				}
				appliedCount++
				modified = true
			}
		}
	}

	if modified && !dryRun {
		var finalLines []string
		for i, line := range lines {
			if !linesToDelete[i] {
				finalLines = append(finalLines, line)
			}
		}
		newContent := strings.Join(finalLines, "\n")
		if err := os.WriteFile(filePath, []byte(newContent), 0644); err != nil {
			fmt.Printf("  [!] Failed to write %s: %v\n", filePath, err)
			return 0
		}
	}

	return appliedCount
}
