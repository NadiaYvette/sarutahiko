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
