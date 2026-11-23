#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-SARUTAHIKO-PROFILE-001] Starting task execution ==="

# 1. Ensure go.mod exists
if [ ! -f go.mod ]; then
  cat << 'EOF' > go.mod
module sarutahiko

go 1.24
EOF
  echo "Created go.mod"
fi

# 2. Add //go:build ignore to hls-autoheal.go and hls_autoheal_test.go if present to prevent multiple main() conflicts
if [ -f scripts/tools/hls-autoheal.go ] && ! grep -q "//go:build ignore" scripts/tools/hls-autoheal.go; then
  sed -i '1s/^/\/\/go:build ignore\n\n/' scripts/tools/hls-autoheal.go
  echo "Added //go:build ignore to scripts/tools/hls-autoheal.go"
fi

if [ -f scripts/tools/hls_autoheal_test.go ] && ! grep -q "//go:build ignore" scripts/tools/hls_autoheal_test.go; then
  sed -i '1s/^/\/\/go:build ignore\n\n/' scripts/tools/hls_autoheal_test.go
  echo "Added //go:build ignore to scripts/tools/hls_autoheal_test.go"
fi

# 3. Write scripts/tools/nadiverse-profile.go
cat << 'EOF' > scripts/tools/nadiverse-profile.go
// nadiverse-profile: Profiling-informed benchmarking analyzer mapping GHC -pj JSON,
// +RTS -s output, and Linux perf stat -j counters onto the 6-layer Performance Chu Space.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type PerfObligation string

const (
	PerfAlloc  PerfObligation = "PerfAlloc"
	PerfGCScan PerfObligation = "PerfGCScan"
	PerfCache  PerfObligation = "PerfCache"
	PerfTLB    PerfObligation = "PerfTLB"
	PerfBranch PerfObligation = "PerfBranch"
	PerfTail   PerfObligation = "PerfTail"
)

type CostCentreHotspot struct {
	Label      string           `json:"label"`
	Module     string           `json:"module"`
	AllocBytes int64            `json:"alloc_bytes"`
	Ticks      int64            `json:"ticks"`
	Entries    int64            `json:"entries"`
	Tags       []PerfObligation `json:"tags"`
}

type RtsStats struct {
	TotalAllocBytes int64   `json:"total_alloc_bytes"`
	CopiedBytes     int64   `json:"copied_bytes"`
	MaxResidency    int64   `json:"max_residency_bytes"`
	ProductivityPct float64 `json:"productivity_pct"`
	Gen1Collections int64   `json:"gen1_collections"`
}

type PerfCounters struct {
	Values      map[string]float64 `json:"values"`
	Uncollected []string           `json:"uncollected"`
}

type Finding struct {
	Obligation  PerfObligation `json:"obligation"`
	Evidence    string         `json:"evidence"`
	Remediation string         `json:"remediation"`
}

type ProfileReport struct {
	TopHotspots []CostCentreHotspot `json:"top_hotspots"`
	RTS         RtsStats            `json:"rts"`
	PMU         PerfCounters        `json:"pmu"`
	Findings    []Finding           `json:"findings"`
}

type ghcProfFile struct {
	CostCentres []struct {
		ID     int    `json:"id"`
		Label  string `json:"label"`
		Module string `json:"module"`
	} `json:"cost_centres"`
	Profile *ghcProfNode `json:"profile"`
}

type ghcProfNode struct {
	ID       int            `json:"id"`
	Entries  int64          `json:"entries"`
	Alloc    int64          `json:"alloc"`
	Ticks    int64          `json:"ticks"`
	Children []*ghcProfNode `json:"children"`
}

func main() {
	profPath := flag.String("prof-json", "", "Path to GHC +RTS -pj JSON profile")
	rtsPath := flag.String("rts-stats", "", "Path to GHC +RTS -s summary text")
	perfPath := flag.String("perf-json", "", "Path to Linux perf stat -j NDJSON output")
	topK := flag.Int("top", 10, "Number of top cost-centre hotspots to emit")
	format := flag.String("format", "md", "Output format: md or json")
	outPath := flag.String("out", "", "Optional output file path (stdout if empty)")
	flag.Parse()

	report := ProfileReport{
		PMU: PerfCounters{Values: make(map[string]float64)},
	}

	if *profPath != "" {
		raw, err := os.ReadFile(*profPath)
		if err != nil {
			fatal(err)
		}
		hotspots, err := parseGhcProfJSON(raw, *topK)
		if err != nil {
			fatal(err)
		}
		report.TopHotspots = hotspots
	}
	if *rtsPath != "" {
		raw, err := os.ReadFile(*rtsPath)
		if err != nil {
			fatal(err)
		}
		report.RTS = parseRtsStats(string(raw))
	}
	if *perfPath != "" {
		raw, err := os.ReadFile(*perfPath)
		if err != nil {
			fatal(err)
		}
		report.PMU = parsePerfStatJSON(string(raw))
	}

	report.Findings = classifyFindings(&report)

	var output string
	if *format == "json" {
		b, err := json.MarshalIndent(report, "", "  ")
		if err != nil {
			fatal(err)
		}
		output = string(b) + "\n"
	} else {
		output = renderMarkdown(report)
	}

	if *outPath != "" {
		if err := os.WriteFile(*outPath, []byte(output), 0o644); err != nil {
			fatal(err)
		}
	} else {
		fmt.Print(output)
	}
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "[nadiverse-profile] error: %v\n", err)
	os.Exit(1)
}

func parseGhcProfJSON(raw []byte, topK int) ([]CostCentreHotspot, error) {
	var doc ghcProfFile
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	ccMeta := make(map[int]struct{ label, mod string }, len(doc.CostCentres))
	for _, cc := range doc.CostCentres {
		ccMeta[cc.ID] = struct{ label, mod string }{cc.Label, cc.Module}
	}
	agg := make(map[int]*CostCentreHotspot)
	var walk func(n *ghcProfNode)
	walk = func(n *ghcProfNode) {
		if n == nil {
			return
		}
		hs, ok := agg[n.ID]
		if !ok {
			meta := ccMeta[n.ID]
			hs = &CostCentreHotspot{Label: meta.label, Module: meta.mod}
			agg[n.ID] = hs
		}
		hs.AllocBytes += n.Alloc
		hs.Ticks += n.Ticks
		hs.Entries += n.Entries
		for _, ch := range n.Children {
			walk(ch)
		}
	}
	walk(doc.Profile)

	res := make([]CostCentreHotspot, 0, len(agg))
	for _, hs := range agg {
		if hs.AllocBytes > 0 || hs.Ticks > 0 {
			res = append(res, *hs)
		}
	}
	sort.Slice(res, func(i, j int) bool {
		if res[i].AllocBytes != res[j].AllocBytes {
			return res[i].AllocBytes > res[j].AllocBytes
		}
		return res[i].Ticks > res[j].Ticks
	})
	if topK > 0 && len(res) > topK {
		res = res[:topK]
	}
	return res, nil
}

var (
	reAllocBytes = regexp.MustCompile(`([0-9,]+)\s+bytes allocated in the heap`)
	reCopied     = regexp.MustCompile(`([0-9,]+)\s+bytes copied during GC`)
	reResidency  = regexp.MustCompile(`([0-9,]+)\s+bytes maximum residency`)
	reProd       = regexp.MustCompile(`Productivity\s+([0-9.]+)%\s+of total user`)
	reGen1       = regexp.MustCompile(`Gen\s+1\s+([0-9,]+)\s+colls`)
)

func parseCommaInt(s string) int64 {
	v, _ := strconv.ParseInt(strings.ReplaceAll(s, ",", ""), 10, 64)
	return v
}

func parseRtsStats(text string) RtsStats {
	var st RtsStats
	if m := reAllocBytes.FindStringSubmatch(text); len(m) == 2 {
		st.TotalAllocBytes = parseCommaInt(m[1])
	}
	if m := reCopied.FindStringSubmatch(text); len(m) == 2 {
		st.CopiedBytes = parseCommaInt(m[1])
	}
	if m := reResidency.FindStringSubmatch(text); len(m) == 2 {
		st.MaxResidency = parseCommaInt(m[1])
	}
	if m := reProd.FindStringSubmatch(text); len(m) == 2 {
		st.ProductivityPct, _ = strconv.ParseFloat(m[1], 64)
	}
	if m := reGen1.FindStringSubmatch(text); len(m) == 2 {
		st.Gen1Collections = parseCommaInt(m[1])
	}
	return st
}

func parsePerfStatJSON(ndjson string) PerfCounters {
	pc := PerfCounters{Values: make(map[string]float64)}
	sc := bufio.NewScanner(strings.NewReader(ndjson))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || !strings.HasPrefix(line, "{") {
			continue
		}
		var row struct {
			Event        string `json:"event"`
			CounterValue string `json:"counter-value"`
		}
		if err := json.Unmarshal([]byte(line), &row); err != nil || row.Event == "" {
			continue
		}
		rawVal := strings.TrimSpace(row.CounterValue)
		if rawVal == "" || strings.HasPrefix(rawVal, "<") {
			pc.Uncollected = append(pc.Uncollected, row.Event)
			continue
		}
		if v, err := strconv.ParseFloat(strings.ReplaceAll(rawVal, ",", ""), 64); err == nil {
			pc.Values[row.Event] = v
		} else {
			pc.Uncollected = append(pc.Uncollected, row.Event)
		}
	}
	sort.Strings(pc.Uncollected)
	return pc
}

func classifyFindings(rep *ProfileReport) []Finding {
	var fs []Finding
	if rep.RTS.ProductivityPct > 0 && rep.RTS.ProductivityPct < 85.0 {
		fs = append(fs, Finding{
			Obligation:  PerfGCScan,
			Evidence:    fmt.Sprintf("Mutator productivity %.1f%% (<85%%), copied=%d B, Gen1=%d", rep.RTS.ProductivityPct, rep.RTS.CopiedBytes, rep.RTS.Gen1Collections),
			Remediation: "Move cold keys/tables into unscanned ByteArray# slabs (Pykinos ART/FAST/WordDSU/BlockedBloom).",
		})
	}
	if rep.RTS.TotalAllocBytes > 100*1024*1024 && len(rep.TopHotspots) > 0 {
		top := rep.TopHotspots[0]
		fs = append(fs, Finding{
			Obligation:  PerfAlloc,
			Evidence:    fmt.Sprintf("Top allocator %s.%s allocated %d B (total=%d B)", top.Module, top.Label, top.AllocBytes, rep.RTS.TotalAllocBytes),
			Remediation: "Check Sub4KB nursery threshold (<3277 B) and use withTransientEpoch / WriterSlab / WordRing.",
		})
	}
	if ins := rep.PMU.Values["instructions"]; ins > 0 {
		if cm := rep.PMU.Values["cache-misses"]; cm/ins > 0.005 {
			fs = append(fs, Finding{
				Obligation:  PerfCache,
				Evidence:    fmt.Sprintf("LLC cache-misses/instr = %.4f (%.1f MPKI)", cm/ins, (cm/ins)*1000),
				Remediation: "Replace pointer-chasing trees with Block-B SoA / WordHeap8 / BlockedBloom.",
			})
		}
		if tlb := rep.PMU.Values["dTLB-load-misses"]; tlb/ins > 0.001 {
			fs = append(fs, Finding{
				Obligation:  PerfTLB,
				Evidence:    fmt.Sprintf("dTLB-load-misses/instr = %.5f", tlb/ins),
				Remediation: "Compact cold subtrees into 4 KiB / 2 MiB FAST superblocks and intern keys to Word32.",
			})
		}
		if bm := rep.PMU.Values["branch-misses"]; bm/ins > 0.005 {
			fs = append(fs, Finding{
				Obligation:  PerfBranch,
				Evidence:    fmt.Sprintf("branch-misses/instr = %.4f", bm/ins),
				Remediation: "Switch to branchless SIMD scans, BitTrie64, or RadixHeap clz/ctz dispatch.",
			})
		}
	}
	return fs
}

func renderMarkdown(rep ProfileReport) string {
	var b strings.Builder
	b.WriteString("# Performance Chu Space Profile Report\n\n")
	if rep.RTS.TotalAllocBytes > 0 {
		fmt.Fprintf(&b, "- **RTS Total Alloc:** %d B | **Copied:** %d B | **Max Residency:** %d B | **Productivity:** %.1f%%\n",
			rep.RTS.TotalAllocBytes, rep.RTS.CopiedBytes, rep.RTS.MaxResidency, rep.RTS.ProductivityPct)
	}
	if len(rep.PMU.Uncollected) > 0 {
		fmt.Fprintf(&b, "- **Uncollected PMU Counters (check perf_event_paranoid):** `%s`\n", strings.Join(rep.PMU.Uncollected, "`, `"))
	}
	b.WriteString("\n## Classified Bottlenecks\n\n")
	if len(rep.Findings) == 0 {
		b.WriteString("No threshold violations detected.\n")
	} else {
		for _, f := range rep.Findings {
			fmt.Fprintf(&b, "- **%s:** %s -> *%s*\n", f.Obligation, f.Evidence, f.Remediation)
		}
	}
	if len(rep.TopHotspots) > 0 {
		b.WriteString("\n## Top Cost-Centre Hotspots\n\n| Module | Cost Centre | Alloc (B) | Ticks | Entries |\n| :--- | :--- | ---: | ---: | ---: |\n")
		for _, h := range rep.TopHotspots {
			fmt.Fprintf(&b, "| `%s` | `%s` | %d | %d | %d |\n", h.Module, h.Label, h.AllocBytes, h.Ticks, h.Entries)
		}
	}
	return b.String()
}
EOF
echo "Wrote scripts/tools/nadiverse-profile.go"

# 4. Write scripts/tools/nadiverse_profile_test.go
cat << 'EOF' > scripts/tools/nadiverse_profile_test.go
package main

import (
	"testing"
)

func TestProfileGhcProfJSON(t *testing.T) {
	sampleJSON := `{
		"cost_centres": [
			{"id": 1, "label": "MAIN", "module": "Main"},
			{"id": 2, "label": "eval", "module": "Cek.Machine"},
			{"id": 3, "label": "lookup", "module": "Pykinos.IntMap.ART"}
		],
		"profile": {
			"id": 1, "entries": 1, "alloc": 1000, "ticks": 10,
			"children": [
				{
					"id": 2, "entries": 100, "alloc": 50000000, "ticks": 500,
					"children": [
						{"id": 3, "entries": 10000, "alloc": 200000000, "ticks": 1200, "children": []}
					]
				}
			]
		}
	}`
	hotspots, err := parseGhcProfJSON([]byte(sampleJSON), 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(hotspots) != 2 {
		t.Fatalf("expected 2 hotspots, got %d", len(hotspots))
	}
	if hotspots[0].Label != "lookup" || hotspots[0].AllocBytes != 200000000 {
		t.Errorf("top hotspot mismatch: %+v", hotspots[0])
	}
}

func TestProfileRtsStats(t *testing.T) {
	sampleText := `
	 254,120,448 bytes allocated in the heap
	  12,450,112 bytes copied during GC
	   8,388,608 bytes maximum residency (2 sample(s))
	  Gen  1        12 colls,     0 par
	  Productivity  82.5% of total user, 79.4% of total elapsed
	`
	st := parseRtsStats(sampleText)
	if st.TotalAllocBytes != 254120448 {
		t.Errorf("expected 254120448 alloc bytes, got %d", st.TotalAllocBytes)
	}
	if st.CopiedBytes != 12450112 {
		t.Errorf("expected 12450112 copied bytes, got %d", st.CopiedBytes)
	}
	if st.MaxResidency != 8388608 {
		t.Errorf("expected 8388608 max residency, got %d", st.MaxResidency)
	}
	if st.Gen1Collections != 12 {
		t.Errorf("expected 12 gen1 colls, got %d", st.Gen1Collections)
	}
	if st.ProductivityPct != 82.5 {
		t.Errorf("expected 82.5 productivity, got %f", st.ProductivityPct)
	}
}

func TestProfilePerfStatJSON(t *testing.T) {
	sampleNDJSON := `
{"event":"instructions","counter-value":"12,500,000,000"}
{"event":"cache-misses","counter-value":"75,000,000"}
{"event":"branch-misses","counter-value":"<not supported>"}
{"event":"dTLB-load-misses","counter-value":"<not counted>"}
{"event":"cycles","counter-value":"5,000,000,000"}
`
	pc := parsePerfStatJSON(sampleNDJSON)
	if pc.Values["instructions"] != 12500000000 {
		t.Errorf("expected instructions 12500000000, got %f", pc.Values["instructions"])
	}
	if pc.Values["cache-misses"] != 75000000 {
		t.Errorf("expected cache-misses 75000000, got %f", pc.Values["cache-misses"])
	}
	if len(pc.Uncollected) != 2 {
		t.Fatalf("expected 2 uncollected counters, got %d (%v)", len(pc.Uncollected), pc.Uncollected)
	}
	if pc.Uncollected[0] != "branch-misses" || pc.Uncollected[1] != "dTLB-load-misses" {
		t.Errorf("unexpected uncollected counters: %v", pc.Uncollected)
	}
}

func TestProfileClassifyFindings(t *testing.T) {
	rep := ProfileReport{
		TopHotspots: []CostCentreHotspot{
			{Label: "step", Module: "Cek", AllocBytes: 150 * 1024 * 1024, Ticks: 100},
		},
		RTS: RtsStats{
			TotalAllocBytes: 200 * 1024 * 1024,
			CopiedBytes:     20 * 1024 * 1024,
			ProductivityPct: 80.0,
			Gen1Collections: 5,
		},
		PMU: PerfCounters{
			Values: map[string]float64{
				"instructions":     1000000000,
				"cache-misses":     10000000,
				"dTLB-load-misses": 2000000,
				"branch-misses":    6000000,
			},
		},
	}
	findings := classifyFindings(&rep)
	obligations := make(map[PerfObligation]bool)
	for _, f := range findings {
		obligations[f.Obligation] = true
	}
	for _, expected := range []PerfObligation{PerfGCScan, PerfAlloc, PerfCache, PerfTLB, PerfBranch} {
		if !obligations[expected] {
			t.Errorf("expected finding for obligation %s", expected)
		}
	}
}
EOF
echo "Wrote scripts/tools/nadiverse_profile_test.go"

# 5. Run verification commands to ensure everything is solid before completing step
go vet ./scripts/tools/nadiverse-profile.go
go build -o /tmp/nadiverse-profile-test ./scripts/tools/nadiverse-profile.go
go test -v -run TestProfile ./scripts/tools/...
echo "=== [TP-SARUTAHIKO-PROFILE-001] Step completed successfully ==="
