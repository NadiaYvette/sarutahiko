//go:build ignore

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
