//go:build ignore

              // #!/usr/bin/env yaegi
              // nadiverse-coverage: Multi-layer Cabal HPC + plugin .tix + Core Lint + should-fail runner.
              package main

              import (
              	"encoding/json"
              	"flag"
              	"fmt"
              	"io/fs"
              	"os"
              	"os/exec"
              	"path/filepath"
              	"sort"
              	"strings"
              )

              var (
              	flagCompiler      = flag.String("compiler", "ghc-9.14.1", "GHC compiler binary")
              	flagProjectFile   = flag.String("project-file", "", "Optional cabal project file (e.g. cabal.project.dev)")
              	flagBuildDir      = flag.String("builddir", "dist-newstyle-hpc", "Isolated Cabal HPC build directory")
              	flagOutDir        = flag.String("out", "dist-newstyle-hpc/hpc-html", "Directory for HPC HTML markup")
              	flagScorecard     = flag.String("scorecard", "dist-newstyle-hpc/scorecard.json", "Path for JSON scorecard output")
              	flagCoreLint      = flag.Bool("core-lint", true, "Pass -dcore-lint when compiling tests")
              	flagPluginTarget  = flag.String("plugin-target", "", "Optional target compiled with HPCTIXFILE to capture GHC plugin ticks")
              	flagShouldFailDir = flag.String("should-fail-dir", "tests/should-fail", "Directory containing negative compile fixtures")
              	flagRegressions   = flag.String("regressions-dir", "test/Regressions", "Directory containing named GHC-style regression tests")
              	flagSkipTest      = flag.Bool("skip-test", false, "Skip cabal v2-test and only inspect existing artifacts")
              )

              type ShouldFailResult struct {
              	Fixture string `json:"fixture"`
              	Passed  bool   `json:"passed"`
              	Detail  string `json:"detail"`
              }

              type Scorecard struct {
              	Compiler          string             `json:"compiler"`
              	BuildDir          string             `json:"builddir"`
              	CoreLintEnabled   bool               `json:"core_lint_enabled"`
              	TixSuites         []string           `json:"tix_suites"`
              	MergedPluginTix   string             `json:"merged_plugin_tix,omitempty"`
              	ShouldFailResults []ShouldFailResult `json:"should_fail_results"`
              	RegressionFiles   []string           `json:"regression_files"`
              	AllGatesPassed    bool               `json:"all_gates_passed"`
              }

              func cabalBaseArgs() []string {
              	args := []string{
              		"--with-compiler=" + *flagCompiler,
              		"--builddir=" + *flagBuildDir,
              	}
              	if *flagProjectFile != "" {
              		args = append(args, "--project-file="+*flagProjectFile)
              	}
              	return args
              }

              func main() {
              	flag.Parse()

              	sc := Scorecard{
              		Compiler:        *flagCompiler,
              		BuildDir:        *flagBuildDir,
              		CoreLintEnabled: *flagCoreLint,
              		AllGatesPassed:  true,
              	}

              	if !*flagSkipTest {
              		if err := runCoverageSuite(); err != nil {
              			fmt.Fprintf(os.Stderr, "[nadiverse-coverage] test suite failed: %v\n", err)
              			sc.AllGatesPassed = false
              			_ = writeScorecardJSON(*flagScorecard, sc)
              			os.Exit(1)
              		}
              	}

              	var pluginTix string
              	if *flagPluginTarget != "" {
              		var err error
              		pluginTix, err = capturePluginTix(*flagPluginTarget)
              		if err != nil {
              			fmt.Fprintf(os.Stderr, "[nadiverse-coverage] plugin .tix capture failed: %v\n", err)
              			sc.AllGatesPassed = false
              		}
              	}

              	tixFiles, mixDirs, err := discoverHPCArtifacts(*flagBuildDir)
              	if err != nil {
              		fmt.Fprintf(os.Stderr, "[nadiverse-coverage] artifact scan failed: %v\n", err)
              		os.Exit(1)
              	}

              	if err := os.MkdirAll(*flagOutDir, 0o755); err != nil {
              		fmt.Fprintf(os.Stderr, "[nadiverse-coverage] mkdir %s failed: %v\n", *flagOutDir, err)
              		os.Exit(1)
              	}

              	for _, tix := range tixFiles {
              		suite := strings.TrimSuffix(filepath.Base(tix), ".tix")
              		sc.TixSuites = append(sc.TixSuites, suite)
              		fmt.Printf("\n=== [hpc report] %s ===\n", suite)
              		if err := runHPC("report", tix, mixDirs, ""); err != nil {
              			fmt.Fprintf(os.Stderr, "[nadiverse-coverage] hpc report failed for %s: %v\n", tix, err)
              			sc.AllGatesPassed = false
              		}
              		dest := filepath.Join(*flagOutDir, suite)
              		_ = os.MkdirAll(dest, 0o755)
              		if err := runHPC("markup", tix, mixDirs, dest); err != nil {
              			fmt.Fprintf(os.Stderr, "[nadiverse-coverage] hpc markup failed for %s: %v\n", tix, err)
              			sc.AllGatesPassed = false
              		}
              	}

              	if pluginTix != "" {
              		mergedPath := filepath.Join(*flagBuildDir, "merged-plugin.tix")
              		allTix := append([]string{pluginTix}, tixFiles...)
              		if err := mergePluginTix(allTix, mergedPath); err != nil {
              			fmt.Fprintf(os.Stderr, "[nadiverse-coverage] hpc sum failed: %v\n", err)
              			sc.AllGatesPassed = false
              		} else {
              			sc.MergedPluginTix = mergedPath
              			fmt.Printf("\n=== [hpc report] merged-plugin ===\n")
              			_ = runHPC("report", mergedPath, mixDirs, "")
              		}
              	}

              	sfResults, sfOk := runShouldFailFixtures(*flagShouldFailDir)
              	sc.ShouldFailResults = sfResults
              	if !sfOk {
              		sc.AllGatesPassed = false
              	}

              	sc.RegressionFiles = discoverRegressions(*flagRegressions)

              	if err := writeScorecardJSON(*flagScorecard, sc); err != nil {
              		fmt.Fprintf(os.Stderr, "[nadiverse-coverage] failed writing scorecard: %v\n", err)
              		os.Exit(1)
              	}
              	fmt.Printf("\n=== [nadiverse-coverage] Scorecard written to %s (all_gates_passed=%v) ===\n",
              		*flagScorecard, sc.AllGatesPassed)
              	if !sc.AllGatesPassed {
              		os.Exit(1)
              	}
              }

              func runCoverageSuite() error {
              	args := append(cabalBaseArgs(), "v2-test", "--enable-coverage")
              	if *flagCoreLint {
              		args = append(args, "--ghc-options=-dcore-lint")
              	}
              	args = append(args, "all")
              	fmt.Printf("=== [nadiverse-coverage] cabal %s ===\n", strings.Join(args, " "))
              	cmd := exec.Command("cabal", args...)
              	cmd.Stdout = os.Stdout
              	cmd.Stderr = os.Stderr
              	return cmd.Run()
              }

              func capturePluginTix(target string) (string, error) {
              	tixPath := filepath.Join(*flagBuildDir, "plugin-compile.tix")
              	_ = os.Remove(tixPath)
              	args := append(cabalBaseArgs(),
              		"v2-build",
              		"--enable-coverage",
              		"--ghc-options=-fforce-recomp",
              	)
              	if *flagCoreLint {
              		args = append(args, "--ghc-options=-dcore-lint")
              	}
              	args = append(args, target)
              	cmd := exec.Command("cabal", args...)
              	cmd.Env = append(os.Environ(), "HPCTIXFILE="+tixPath)
              	cmd.Stdout = os.Stdout
              	cmd.Stderr = os.Stderr
              	if err := cmd.Run(); err != nil {
              		return "", err
              	}
              	if _, err := os.Stat(tixPath); err != nil {
              		return "", fmt.Errorf("expected plugin .tix not produced at %s", tixPath)
              	}
              	return tixPath, nil
              }

              func mergePluginTix(inputs []string, outPath string) error {
              	args := append([]string{"sum", "--union", "--output=" + outPath}, inputs...)
              	cmd := exec.Command("hpc", args...)
              	cmd.Stdout = os.Stdout
              	cmd.Stderr = os.Stderr
              	return cmd.Run()
              }

              func runShouldFailFixtures(dir string) ([]ShouldFailResult, bool) {
              	var results []ShouldFailResult
              	if _, err := os.Stat(dir); os.IsNotExist(err) {
              		return results, true
              	}
              	allOk := true
              	entries, err := os.ReadDir(dir)
              	if err != nil {
              		return results, false
              	}
              	for _, e := range entries {
              		if e.IsDir() || !strings.HasSuffix(e.Name(), ".hs") {
              			continue
              		}
              		hsPath := filepath.Join(dir, e.Name())
              		expPath := strings.TrimSuffix(hsPath, ".hs") + ".stderr.expected"
              		args := append(cabalBaseArgs(), "v2-exec", "--", *flagCompiler, "-fno-code", hsPath)
              		cmd := exec.Command("cabal", args...)
              		outBytes, runErr := cmd.CombinedOutput()
              		outStr := string(outBytes)

              		if runErr == nil {
              			results = append(results, ShouldFailResult{
              				Fixture: hsPath,
              				Passed:  false,
              				Detail:  "unexpectedly compiled cleanly (expected failure)",
              			})
              			allOk = false
              			continue
              		}

              		expBytes, readErr := os.ReadFile(expPath)
              		if readErr == nil {
              			missing := ""
              			for _, line := range strings.Split(string(expBytes), "\n") {
              				trimmed := strings.TrimSpace(line)
              				if trimmed == "" || strings.HasPrefix(trimmed, "#") {
              					continue
              				}
              				if !strings.Contains(outStr, trimmed) {
              					missing = trimmed
              					break
              				}
              			}
              			if missing != "" {
              				results = append(results, ShouldFailResult{
              					Fixture: hsPath,
              					Passed:  false,
              					Detail:  "failed as expected, but missing diagnostic substring: " + missing,
              				})
              				allOk = false
              				continue
              			}
              		}

              		results = append(results, ShouldFailResult{
              			Fixture: hsPath,
              			Passed:  true,
              			Detail:  "rejected with expected diagnostic",
              		})
              	}
              	return results, allOk
              }

              func discoverRegressions(dir string) []string {
              	var found []string
              	if _, err := os.Stat(dir); os.IsNotExist(err) {
              		return found
              	}
              	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
              		if err == nil && !d.IsDir() && strings.HasSuffix(d.Name(), ".hs") {
              			found = append(found, path)
              		}
              		return nil
              	})
              	sort.Strings(found)
              	return found
              }

              func discoverHPCArtifacts(root string) ([]string, []string, error) {
              	var tix []string
              	mixSet := make(map[string]struct{})
              	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
              		if walkErr != nil {
              			return nil
              		}
              		if !d.IsDir() && strings.HasSuffix(d.Name(), ".tix") && d.Name() != "merged-plugin.tix" && d.Name() != "plugin-compile.tix" {
              			tix = append(tix, path)
              		}
              		if d.IsDir() && d.Name() == "mix" {
              			mixSet[path] = struct{}{}
              			if sub, rErr := os.ReadDir(path); rErr == nil {
              				for _, e := range sub {
              					if e.IsDir() {
              						mixSet[filepath.Join(path, e.Name())] = struct{}{}
              					}
              				}
              			}
              		}
              		return nil
              	})
              	if err != nil {
              		return nil, nil, err
              	}
              	sort.Strings(tix)
              	mixDirs := make([]string, 0, len(mixSet))
              	for m := range mixSet {
              		mixDirs = append(mixDirs, m)
              	}
              	sort.Strings(mixDirs)
              	return tix, mixDirs, nil
              }

              func runHPC(subcmd, tix string, mixDirs []string, destDir string) error {
              	args := []string{subcmd, tix, "--exclude=Main"}
              	for _, m := range mixDirs {
              		args = append(args, "--hpcdir="+m)
              	}
              	if destDir != "" {
              		args = append(args, "--destdir="+destDir)
              	}
              	cmd := exec.Command("hpc", args...)
              	cmd.Stdout = os.Stdout
              	cmd.Stderr = os.Stderr
              	return cmd.Run()
              }

              func writeScorecardJSON(path string, sc Scorecard) error {
              	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
              		return err
              	}
              	raw, err := json.MarshalIndent(sc, "", "  ")
              	if err != nil {
              		return err
              	}
              	return os.WriteFile(path, append(raw, '\n'), 0o644)
              }
              