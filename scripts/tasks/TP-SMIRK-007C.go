package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func findSeed(name string) string {
	candidates := []string{
		filepath.Join("seeds", name),
		filepath.Join(os.Getenv("HOME"), "src/plans/seeds", name),
		filepath.Join("..", "seeds", name),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return filepath.Join("seeds", name)
}

func main() {
	fmt.Println("=== [TP-SMIRK-007C Task Runner (Go)] ===")

	// 1. Copy SmirkGate.hs
	srcGate := findSeed("TP-SMIRK-007C-SmirkGate.hs")
	dstGate := "packages/yamaarashi/yamaarashi/src/Yamaarashi/Synthesis/SmirkGate.hs"
	if err := copyFile(srcGate, dstGate); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcGate, dstGate, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstGate)

	// 2. Copy SmirkSynthBench.hs
	srcBench := findSeed("TP-SMIRK-007C-SmirkSynthBench.hs")
	dstBench := "packages/yamaarashi/yamaarashi/bench/SmirkSynthBench.hs"
	if err := copyFile(srcBench, dstBench); err != nil {
		fmt.Fprintf(os.Stderr, "failed to copy %s -> %s: %v\n", srcBench, dstBench, err)
		os.Exit(1)
	}
	fmt.Printf("  [+] Mounted %s\n", dstBench)

	// 3. Update packages/yamaarashi/yamaarashi/yamaarashi.cabal
	cabalPath := "packages/yamaarashi/yamaarashi/yamaarashi.cabal"
	cabalBytes, err := os.ReadFile(cabalPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	cabalStr := string(cabalBytes)
	if !strings.Contains(cabalStr, "Yamaarashi.Synthesis.SmirkGate") {
		cabalStr = strings.Replace(cabalStr,
			"        Yamaarashi.Synthesis.Synquid\n",
			"        Yamaarashi.Synthesis.Synquid\n        Yamaarashi.Synthesis.SmirkGate\n", 1)
	}
	if !strings.Contains(cabalStr, "executable yamaarashi-smirk-synth-bench") {
		benchStanza := `
executable yamaarashi-smirk-synth-bench
    import:           commons
    main-is:          SmirkSynthBench.hs
    hs-source-dirs:   bench
    build-depends:
        base >= 4.20 && < 5,
        containers,
        text,
        yamaarashi
`
		cabalStr += benchStanza
	}
	if err := os.WriteFile(cabalPath, []byte(cabalStr), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", cabalPath, err)
		os.Exit(1)
	}
	fmt.Println("  [+] Updated yamaarashi.cabal")

	// 4. Update packages/yamaarashi/yamaarashi/test/Spec.hs
	specPath := "packages/yamaarashi/yamaarashi/test/Spec.hs"
	specBytes, err := os.ReadFile(specPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", specPath, err)
		os.Exit(1)
	}
	specStr := string(specBytes)
	if !strings.Contains(specStr, "Yamaarashi.Synthesis.SmirkGate") {
		specStr = strings.Replace(specStr,
			"import Yamaarashi.Synthesis.Synquid\n",
			"import qualified Yamaarashi.Synthesis.SmirkGate as SmirkGate\nimport Yamaarashi.Synthesis.Synquid\n", 1)

		gatePropSnippet := `
prop_smirkGate_synthesize :: Property
prop_smirkGate_synthesize = property $ do
  res <- evalIO SmirkGate.runSmirkSynthesisBenchmark
  SmirkGate.brSuccess res === True
  SmirkGate.brSynthesizedAST res /== Nothing
`
		specStr = strings.Replace(specStr,
			"  , testGroup \"Yamaarashi.Synthesis.Synquid\"\n",
			"  , testGroup \"Yamaarashi.Synthesis.SmirkGate\"\n      [ testProperty \"deductively synthesizes Penelope regex pipeline from PortSig contract\" prop_smirkGate_synthesize ]\n  , testGroup \"Yamaarashi.Synthesis.Synquid\"\n", 1)

		specStr += "\n" + gatePropSnippet
		if err := os.WriteFile(specPath, []byte(specStr), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write %s: %v\n", specPath, err)
			os.Exit(1)
		}
		fmt.Println("  [+] Updated test/Spec.hs")
	}

	fmt.Println("=== [TP-SMIRK-007C Task Runner Complete] ===")
}
