// nadiverse-rollup: Roll git repositories (working tree, worktree-safe branch
// snapshots, single branch deltas, or auto-discovered multi-branch deltas) into
// structured Markdown digests with dual char/word auto-sharding and Cross-Shard TOC.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type RollupConfig struct {
	RepoDir           string
	Prefix            string
	Ref               string // Optional git ref/branch (reads object DB without touching worktree)
	Base              string // Optional base ref/tag (or "auto"); enables branch-delta mode
	AllBranches       bool   // Auto-discover all relevant local branches and pack their deltas into one sharded digest
	ListBranches      bool   // Print discovered branch selection/skip table and exit
	BranchInclude     string // Optional comma-separated glob whitelist for -all-branches
	BranchExclude     string // Comma-separated glob blacklist for -all-branches
	MaxDeltaCommits   int    // Skip branches with >N commits ahead of base in -all-branches (0 disables)
	StackAncestors    bool   // In -all-branches, diff descendants against nearest selected ancestor branch
	DiffContext       int    // Unified diff context lines for modified files in delta mode
	DeltaFullModified bool   // Emit full file contents instead of unified diffs for modified files in delta mode
	Key               string
	DocTitle          string
	Tier              string // "arch" or "full"
	MaxChars          int
	MaxWords          int
	AutoShard         bool
	Exclude           string // comma-separated extra file exclude patterns
	NoDefaultExcludes bool
	OutFile           string
	MapFile           string
	DryRun            bool
	CreateMissing     bool
	UploadBaseURL     string
	TokenURL          string
}

type RollupStats struct {
	CommitSHA string
	Files     int
	Bytes     int
	Runes     int
	Words     int
}

type RollupMeta struct {
	RepoName     string
	Prefix       string
	Ref          string
	Base         string
	MergeBaseSHA string
	CommitSHA    string
	CommitTime   string
	Mode         string // "worktree", "branch-snapshot", "branch-delta", or "all-branches-delta"
}

type fileEntry struct {
	path         string
	content      string
	langOverride string
}

type fileBlock struct {
	path     string
	rendered string
	runes    int
	words    int
}

type RollupShard struct {
	Index    int
	Total    int
	Key      string
	Title    string
	Markdown string
	Stats    RollupStats
	Blocks   []fileBlock
}

type rawBranch struct {
	Name       string
	OID        string
	Upstream   string
	IsHead     bool
	Subject    string
}

type selectedBranch struct {
	Name          string
	OID           string
	Aliases       []string
	IsHead        bool
	Subject       string
	RootBase      string
	BaseRef       string
	MergeBaseFull string
	Ahead         int
	StackedOn     string
}

type skippedBranch struct {
	Name   string
	OID    string
	Reason string
}

type branchPlan struct {
	DefaultBase string
	Selected    []selectedBranch
	Skipped     []skippedBranch
}

func main() {
	cfg := RollupConfig{}
	flag.StringVar(&cfg.RepoDir, "repo", ".", "Path to git repository")
	flag.StringVar(&cfg.Prefix, "prefix", "", "Optional tracked path prefix (e.g. packages/kogaki or mm/)")
	flag.StringVar(&cfg.Ref, "ref", "", "Optional git ref/branch to snapshot directly from git object DB (worktree-safe)")
	flag.StringVar(&cfg.Base, "base", "", "Optional upstream base ref/tag (or 'auto'); enables branch-delta mode")
	flag.BoolVar(&cfg.AllBranches, "all-branches", false, "Auto-discover relevant local branches and pack their deltas into one sharded digest")
	flag.BoolVar(&cfg.ListBranches, "list-branches", false, "Discover and print selected/skipped branches for -repo and exit")
	flag.StringVar(&cfg.BranchInclude, "branch-include", "", "Optional comma-separated glob whitelist for -all-branches (e.g. 'nadia.*,juli-*')")
	flag.StringVar(&cfg.BranchExclude, "branch-exclude", "backup/*,pre-rebase*,*-backup,debug/*,akpm/*", "Comma-separated glob blacklist for -all-branches")
	flag.IntVar(&cfg.MaxDeltaCommits, "max-delta-commits", 400, "Skip branches with more than N commits ahead of base in -all-branches (0 disables)")
	flag.BoolVar(&cfg.StackAncestors, "stack-ancestors", true, "In -all-branches, diff descendant branches against their nearest selected ancestor to avoid duplicate diffs")
	flag.IntVar(&cfg.DiffContext, "diff-context", 8, "Unified diff context lines for modified files in delta mode")
	flag.BoolVar(&cfg.DeltaFullModified, "delta-full-modified", false, "In delta mode, emit full contents of modified files instead of unified diffs")
	flag.StringVar(&cfg.Key, "key", "", "Lookup key in -map-file (default derived from repo, ref, and prefix)")
	flag.StringVar(&cfg.DocTitle, "title", "", "Google Doc title when creating a new doc")
	flag.StringVar(&cfg.Tier, "tier", "arch", "Digest tier: 'arch' (interfaces+docs) or 'full'")
	flag.IntVar(&cfg.MaxChars, "max-chars", 800000, "Max Unicode character count per shard (0 disables; Google Docs cap ~1.02M)")
	flag.IntVar(&cfg.MaxWords, "max-words", 400000, "Max word count per shard (0 disables; Gemini Notebook cap ~500K)")
	flag.BoolVar(&cfg.AutoShard, "auto-shard", true, "Automatically bin-pack into whole-file part-01..part-NN shards when exceeding caps")
	flag.StringVar(&cfg.Exclude, "exclude", "", "Comma-separated extra file exclude patterns (e.g. 'examples/,witnesses/')")
	flag.BoolVar(&cfg.NoDefaultExcludes, "no-default-excludes", false, "Include default-excluded bulk assets (*.min.js, *.min.css, docs/transcripts/, corpus/, LaTeX aux)")
	flag.StringVar(&cfg.OutFile, "out", "", "Optional local path to write Markdown digest (multi-shard inserts .part-NN before ext)")
	flag.StringVar(&cfg.MapFile, "map-file", defaultMapPath(), "JSON file mapping rollup keys to Drive Doc IDs")
	flag.BoolVar(&cfg.DryRun, "dry-run", false, "Build digest locally without calling Google Drive API")
	flag.BoolVar(&cfg.CreateMissing, "create-missing", false, "Create new Google Doc(s) if key is absent from -map-file")
	flag.StringVar(&cfg.UploadBaseURL, "upload-base", "https://www.googleapis.com/upload/drive/v3", "Drive upload API base URL")
	flag.StringVar(&cfg.TokenURL, "token-url", "https://oauth2.googleapis.com/token", "OAuth2 token endpoint")
	flag.Parse()

	if err := runRollup(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "[nadiverse-rollup] error: %v\n", err)
		os.Exit(1)
	}
}

func defaultMapPath() string {
	if cfgDir, err := os.UserConfigDir(); err == nil && cfgDir != "" {
		return filepath.Join(cfgDir, "nadiverse", "rollup-map.json")
	}
	return ".rollup-map.json"
}

func countWords(s string) int {
	n := 0
	inWord := false
	for _, r := range s {
		if unicode.IsSpace(r) {
			inWord = false
		} else if !inWord {
			inWord = true
			n++
		}
	}
	return n
}

func runRollup(cfg RollupConfig) error {
	absRepo, err := filepath.Abs(cfg.RepoDir)
	if err != nil {
		return err
	}
	cfg.RepoDir = absRepo
	repoName := filepath.Base(absRepo)
	cleanPrefix := strings.Trim(filepath.ToSlash(cfg.Prefix), "/")

	if cfg.ListBranches {
		plan, err := discoverRelevantBranches(cfg)
		if err != nil {
			return err
		}
		fmt.Printf("=== %s (default base: %s) ===\n", repoName, plan.DefaultBase)
		fmt.Printf("Selected (%d):\n", len(plan.Selected))
		for _, b := range plan.Selected {
			headMark := " "
			if b.IsHead {
				headMark = "*"
			}
			aliasStr := ""
			if len(b.Aliases) > 0 {
				aliasStr = " [aliases: " + strings.Join(b.Aliases, ", ") + "]"
			}
			stackStr := ""
			if b.StackedOn != "" {
				stackStr = fmt.Sprintf(" (stacked on %s)", b.StackedOn)
			}
			fmt.Printf("  %s %-46s %s  +%d vs %s%s%s\n",
				headMark, b.Name, shortSHA(b.OID), b.Ahead, b.BaseRef, stackStr, aliasStr)
		}
		fmt.Printf("Skipped (%d):\n", len(plan.Skipped))
		for _, s := range plan.Skipped {
			fmt.Printf("  - %-46s %s  (%s)\n", s.Name, shortSHA(s.OID), s.Reason)
		}
		return nil
	}

	if cfg.Key == "" {
		key := repoName
		if cfg.AllBranches {
			key += ":branches"
		} else if cfg.Ref != "" {
			key += "@" + cfg.Ref
		}
		if cleanPrefix != "" {
			key += ":" + cleanPrefix
		}
		cfg.Key = key
	}
	if cfg.DocTitle == "" {
		switch {
		case cfg.AllBranches:
			cfg.DocTitle = fmt.Sprintf("Rollup: %s (all branches delta)", cfg.Key)
		case cfg.Base != "":
			targetRef := cfg.Ref
			if targetRef == "" {
				targetRef = "HEAD"
			}
			cfg.DocTitle = fmt.Sprintf("Rollup: %s (delta %s..%s)", cfg.Key, cfg.Base, targetRef)
		default:
			cfg.DocTitle = fmt.Sprintf("Rollup: %s (%s)", cfg.Key, cfg.Tier)
		}
	}

	shards, meta, err := buildRollupShards(cfg, repoName, cleanPrefix)
	if err != nil {
		return err
	}

	totalFiles, totalRunes, totalWords := 0, 0, 0
	for _, sh := range shards {
		totalFiles += sh.Stats.Files
		totalRunes += sh.Stats.Runes
		totalWords += sh.Stats.Words
		fmt.Printf("[nadiverse-rollup] key=%s mode=%s part=%02d/%02d tier=%s commit=%s files=%d runes=%d words=%d bytes=%d\n",
			sh.Key, meta.Mode, sh.Index, sh.Total, cfg.Tier, sh.Stats.CommitSHA, sh.Stats.Files, sh.Stats.Runes, sh.Stats.Words, sh.Stats.Bytes)

		if cfg.MaxChars > 0 && sh.Stats.Runes > cfg.MaxChars {
			return fmt.Errorf("shard %s (%02d/%02d) has %d characters, exceeding -max-chars=%d",
				sh.Key, sh.Index, sh.Total, sh.Stats.Runes, cfg.MaxChars)
		}
		if cfg.MaxWords > 0 && sh.Stats.Words > cfg.MaxWords {
			return fmt.Errorf("shard %s (%02d/%02d) has %d words, exceeding -max-words=%d",
				sh.Key, sh.Index, sh.Total, sh.Stats.Words, cfg.MaxWords)
		}
	}
	if len(shards) > 1 {
		fmt.Printf("[nadiverse-rollup] total shards=%d blocks=%d runes=%d words=%d\n",
			len(shards), totalFiles, totalRunes, totalWords)
	}

	if cfg.OutFile != "" {
		for _, sh := range shards {
			outPath := shardOutPath(cfg.OutFile, sh.Index, sh.Total)
			if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(outPath, []byte(sh.Markdown), 0o644); err != nil {
				return err
			}
			fmt.Printf("[nadiverse-rollup] wrote %s\n", outPath)
		}
	}

	if cfg.DryRun {
		return nil
	}

	client := &http.Client{Timeout: 90 * time.Second}
	token, err := resolveAccessToken(client, cfg.TokenURL)
	if err != nil {
		return err
	}

	for _, sh := range shards {
		docID, created, err := upsertGoogleDoc(client, cfg, sh.Key, sh.Title, token, sh.Markdown)
		if err != nil {
			return fmt.Errorf("uploading %s: %w", sh.Key, err)
		}
		action := "updated in place"
		if created {
			action = "created (attach once to Gemini Notebook)"
		}
		fmt.Printf("[nadiverse-rollup] %s [%s]: https://docs.google.com/document/d/%s/edit\n", action, sh.Title, docID)
	}

	warnStaleShards(cfg.MapFile, cfg.Key, len(shards))
	return nil
}

func shortSHA(oid string) string {
	if len(oid) > 12 {
		return oid[:12]
	}
	return oid
}

func shardOutPath(basePath string, idx, total int) string {
	if total <= 1 {
		return basePath
	}
	ext := filepath.Ext(basePath)
	stem := strings.TrimSuffix(basePath, ext)
	return fmt.Sprintf("%s.part-%02d%s", stem, idx, ext)
}

func warnStaleShards(mapFile, baseKey string, activeCount int) {
	data, err := os.ReadFile(mapFile)
	if err != nil {
		return
	}
	mapData := make(map[string]string)
	if err := json.Unmarshal(data, &mapData); err != nil {
		return
	}
	partPrefix := baseKey + ":part-"
	var stale []string
	for k := range mapData {
		if !strings.HasPrefix(k, partPrefix) {
			continue
		}
		numStr := strings.TrimPrefix(k, partPrefix)
		n, err := strconv.Atoi(numStr)
		if err == nil && n > activeCount {
			stale = append(stale, k)
		}
	}
	sort.Strings(stale)
	if len(stale) > 0 {
		fmt.Printf("[nadiverse-rollup] note: %s still maps older unused shard key(s): %s\n",
			mapFile, strings.Join(stale, ", "))
	}
}

func gitCmdBytes(repoDir string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = repoDir
	var out bytes.Buffer
	var errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(errOut.String()))
	}
	return out.Bytes(), nil
}

func gitCmd(repoDir string, args ...string) (string, error) {
	b, err := gitCmdBytes(repoDir, args...)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func splitCSV(csv string) []string {
	if strings.TrimSpace(csv) == "" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(csv, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func matchBranchGlob(branch, pat string) bool {
	if strings.HasSuffix(pat, "/*") {
		prefix := strings.TrimSuffix(pat, "*")
		if strings.HasPrefix(branch, prefix) {
			return true
		}
	}
	if strings.HasPrefix(pat, "*") && !strings.Contains(pat[1:], "*") {
		return strings.HasSuffix(branch, pat[1:])
	}
	if strings.HasSuffix(pat, "*") && !strings.Contains(pat[:len(pat)-1], "*") {
		return strings.HasPrefix(branch, pat[:len(pat)-1])
	}
	ok, err := filepath.Match(pat, branch)
	return err == nil && ok
}

func matchesAnyBranchGlob(branch string, pats []string) bool {
	for _, p := range pats {
		if matchBranchGlob(branch, p) {
			return true
		}
	}
	return false
}

// detectPersonalRemotes identifies mirror remotes (github, sourcehut, etc.)
// and marks origin as personal iff its fetch URL matches any known mirror URL.
func detectPersonalRemotes(repoDir string) map[string]bool {
	personal := map[string]bool{
		"github":    true,
		"gitlab":    true,
		"sourcehut": true,
		"disroot":   true,
		"framagit":  true,
		"atom":      true,
		"rad":       true,
		"all":       true,
	}
	out, err := gitCmd(repoDir, "remote", "-v")
	if err != nil {
		return personal
	}
	mirrorURLs := make(map[string]bool)
	var originURLs []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		rem, rawURL := fields[0], strings.TrimSuffix(fields[1], ".git")
		if personal[rem] {
			mirrorURLs[rawURL] = true
		} else if rem == "origin" {
			originURLs = append(originURLs, rawURL)
		}
	}
	for _, u := range originURLs {
		if mirrorURLs[u] {
			personal["origin"] = true
			break
		}
	}
	return personal
}

func resolveDefaultBase(repoDir, requested string) (string, error) {
	if requested != "" && requested != "auto" {
		if _, err := gitCmd(repoDir, "rev-parse", "--verify", "--quiet", requested+"^{commit}"); err != nil {
			return "", fmt.Errorf("requested -base %q is not a valid commit ref: %w", requested, err)
		}
		return requested, nil
	}
	if sym, err := gitCmd(repoDir, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"); err == nil {
		s := strings.TrimSpace(sym)
		if s != "" {
			if _, err := gitCmd(repoDir, "rev-parse", "--verify", "--quiet", s+"^{commit}"); err == nil {
				return s, nil
			}
		}
	}
	candidates := []string{"origin/master", "origin/main", "master", "main"}
	for _, c := range candidates {
		if _, err := gitCmd(repoDir, "rev-parse", "--verify", "--quiet", c+"^{commit}"); err == nil {
			return c, nil
		}
	}
	return "", errors.New("could not auto-detect default base ref (tried origin/HEAD, origin/master, origin/main, master, main); pass -base explicitly")
}

func listLocalBranches(repoDir string) ([]rawBranch, error) {
	out, err := gitCmd(repoDir, "for-each-ref",
		"--format=%(refname:short)%00%(objectname)%00%(upstream:short)%00%(HEAD)%00%(subject)",
		"refs/heads")
	if err != nil {
		return nil, fmt.Errorf("git for-each-ref: %w", err)
	}
	var branches []rawBranch
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\x00")
		if len(parts) < 5 {
			continue
		}
		branches = append(branches, rawBranch{
			Name:     parts[0],
			OID:      parts[1],
			Upstream: parts[2],
			IsHead:   strings.TrimSpace(parts[3]) == "*",
			Subject:  parts[4],
		})
	}
	return branches, nil
}

func revListCount(repoDir, revRange string) (int, error) {
	out, err := gitCmd(repoDir, "rev-list", "--count", revRange)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(out))
}

func isStrictAncestor(repoDir, ancOID, descOID string) bool {
	if ancOID == descOID {
		return false
	}
	cmd := exec.Command("git", "merge-base", "--is-ancestor", ancOID, descOID)
	cmd.Dir = repoDir
	return cmd.Run() == nil
}

func branchPriorityLess(a, b rawBranch) bool {
	if a.IsHead != b.IsHead {
		return a.IsHead
	}
	aNadia := strings.HasPrefix(a.Name, "nadia.")
	bNadia := strings.HasPrefix(b.Name, "nadia.")
	if aNadia != bNadia {
		return aNadia
	}
	if len(a.Name) != len(b.Name) {
		return len(a.Name) < len(b.Name)
	}
	return a.Name < b.Name
}

func discoverRelevantBranches(cfg RollupConfig) (branchPlan, error) {
	defaultBase, err := resolveDefaultBase(cfg.RepoDir, cfg.Base)
	if err != nil {
		return branchPlan{}, err
	}
	personalRemotes := detectPersonalRemotes(cfg.RepoDir)
	includePats := splitCSV(cfg.BranchInclude)
	excludePats := splitCSV(cfg.BranchExclude)

	raws, err := listLocalBranches(cfg.RepoDir)
	if err != nil {
		return branchPlan{}, err
	}

	plan := branchPlan{DefaultBase: defaultBase}

	// Group by commit OID first so duplicate tips pick one canonical branch name.
	byOID := make(map[string][]rawBranch)
	var keptOIDs []string

	for _, rb := range raws {
		if len(includePats) > 0 && !matchesAnyBranchGlob(rb.Name, includePats) {
			plan.Skipped = append(plan.Skipped, skippedBranch{rb.Name, rb.OID, "not matched by -branch-include"})
			continue
		}
		if matchesAnyBranchGlob(rb.Name, excludePats) {
			plan.Skipped = append(plan.Skipped, skippedBranch{rb.Name, rb.OID, "excluded by -branch-exclude"})
			continue
		}
		if _, seen := byOID[rb.OID]; !seen {
			keptOIDs = append(keptOIDs, rb.OID)
		}
		byOID[rb.OID] = append(byOID[rb.OID], rb)
	}

	for _, oid := range keptOIDs {
		group := byOID[oid]
		sort.Slice(group, func(i, j int) bool { return branchPriorityLess(group[i], group[j]) })
		primary := group[0]
		var aliases []string
		for _, dup := range group[1:] {
			aliases = append(aliases, dup.Name)
		}

		// Determine per-branch root base: if any branch in the group tracks a non-personal upstream remote,
		// use that upstream ref (so tracking branches like kas/pte_size or akpm/mm-everything diff properly).
		rootBase := defaultBase
		for _, cand := range group {
			if cand.Upstream == "" {
				continue
			}
			rem := strings.SplitN(cand.Upstream, "/", 2)[0]
			if rem != "" && !personalRemotes[rem] {
				if _, err := gitCmd(cfg.RepoDir, "rev-parse", "--verify", "--quiet", cand.Upstream+"^{commit}"); err == nil {
					rootBase = cand.Upstream
					break
				}
			}
		}

		mbOut, err := gitCmd(cfg.RepoDir, "merge-base", rootBase, primary.OID)
		if err != nil {
			plan.Skipped = append(plan.Skipped, skippedBranch{primary.Name, primary.OID, "no common ancestor with " + rootBase})
			continue
		}
		mergeBaseFull := strings.TrimSpace(mbOut)

		ahead, err := revListCount(cfg.RepoDir, mergeBaseFull+".."+primary.OID)
		if err != nil {
			plan.Skipped = append(plan.Skipped, skippedBranch{primary.Name, primary.OID, "rev-list error"})
			continue
		}
		if ahead == 0 {
			reason := fmt.Sprintf("0 commits ahead of %s", rootBase)
			plan.Skipped = append(plan.Skipped, skippedBranch{primary.Name, primary.OID, reason})
			for _, a := range aliases {
				plan.Skipped = append(plan.Skipped, skippedBranch{a, primary.OID, reason})
			}
			continue
		}
		if cfg.MaxDeltaCommits > 0 && ahead > cfg.MaxDeltaCommits {
			reason := fmt.Sprintf("%d commits ahead of %s (exceeds -max-delta-commits=%d)", ahead, rootBase, cfg.MaxDeltaCommits)
			plan.Skipped = append(plan.Skipped, skippedBranch{primary.Name, primary.OID, reason})
			for _, a := range aliases {
				plan.Skipped = append(plan.Skipped, skippedBranch{a, primary.OID, reason})
			}
			continue
		}

		for _, a := range aliases {
			plan.Skipped = append(plan.Skipped, skippedBranch{a, primary.OID, "same tip as " + primary.Name})
		}

		plan.Selected = append(plan.Selected, selectedBranch{
			Name:          primary.Name,
			OID:           primary.OID,
			Aliases:       aliases,
			IsHead:        primary.IsHead,
			Subject:       primary.Subject,
			RootBase:      rootBase,
			BaseRef:       rootBase,
			MergeBaseFull: mergeBaseFull,
			Ahead:         ahead,
		})
	}

	// Optional ancestor stacking: diff descendant branches against their nearest selected ancestor
	// sharing the same RootBase so stacked topic branches never duplicate parent patchsets.
	if cfg.StackAncestors && len(plan.Selected) > 1 {
		origAhead := make([]int, len(plan.Selected))
		for i, b := range plan.Selected {
			origAhead[i] = b.Ahead
		}
		for i := range plan.Selected {
			bestParent := -1
			bestParentAhead := -1
			for j := range plan.Selected {
				if i == j {
					continue
				}
				if plan.Selected[i].RootBase != plan.Selected[j].RootBase {
					continue
				}
				if origAhead[j] >= origAhead[i] {
					continue
				}
				if isStrictAncestor(cfg.RepoDir, plan.Selected[j].OID, plan.Selected[i].OID) {
					if origAhead[j] > bestParentAhead {
						bestParent = j
						bestParentAhead = origAhead[j]
					}
				}
			}
			if bestParent >= 0 {
				parent := plan.Selected[bestParent]
				if incAhead, err := revListCount(cfg.RepoDir, parent.OID+".."+plan.Selected[i].OID); err == nil && incAhead > 0 {
					plan.Selected[i].BaseRef = parent.Name
					plan.Selected[i].MergeBaseFull = parent.OID
					plan.Selected[i].Ahead = incAhead
					plan.Selected[i].StackedOn = parent.Name
				}
			}
		}
	}

	// Sort selected branches: root branches first (HEAD first, then alphabetical), then stacked descendants.
	sort.Slice(plan.Selected, func(i, j int) bool {
		a, b := plan.Selected[i], plan.Selected[j]
		if (a.StackedOn != "") != (b.StackedOn != "") {
			return a.StackedOn == ""
		}
		if a.IsHead != b.IsHead {
			return a.IsHead
		}
		return a.Name < b.Name
	})
	sort.Slice(plan.Skipped, func(i, j int) bool { return plan.Skipped[i].Name < plan.Skipped[j].Name })

	return plan, nil
}

func renderBranchesSummaryMD(repoName string, plan branchPlan) string {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("# Discovered Branch Delta Summary: `%s`\n\n", repoName))
	sb.WriteString(fmt.Sprintf("- **Default Base:** `%s`\n", plan.DefaultBase))
	sb.WriteString(fmt.Sprintf("- **Selected Branches:** %d\n", len(plan.Selected)))
	sb.WriteString(fmt.Sprintf("- **Skipped Branches:** %d\n\n", len(plan.Skipped)))

	sb.WriteString("## Selected Branches\n\n")
	sb.WriteString("| Branch | Commit | Ahead | Diff Base | Aliases | Tip Subject |\n")
	sb.WriteString("| :--- | :--- | ---: | :--- | :--- | :--- |\n")
	for _, b := range plan.Selected {
		aliases := "-"
		if len(b.Aliases) > 0 {
			aliases = "`" + strings.Join(b.Aliases, "`, `") + "`"
		}
		baseCol := "`" + b.BaseRef + "`"
		if b.StackedOn != "" {
			baseCol += " *(stacked)*"
		}
		subj := strings.ReplaceAll(b.Subject, "|", "\\|")
		sb.WriteString(fmt.Sprintf("| `%s` | `%s` | %d | %s | %s | %s |\n",
			b.Name, shortSHA(b.OID), b.Ahead, baseCol, aliases, subj))
	}

	if len(plan.Skipped) > 0 {
		sb.WriteString("\n## Skipped Branches\n\n")
		sb.WriteString("| Branch | Commit | Reason |\n")
		sb.WriteString("| :--- | :--- | :--- |\n")
		for _, s := range plan.Skipped {
			sb.WriteString(fmt.Sprintf("| `%s` | `%s` | %s |\n", s.Name, shortSHA(s.OID), s.Reason))
		}
	}
	sb.WriteString("\n")
	return sb.String()
}

func loadRollupIgnore(repoDir, ref, extraCSV string) []string {
	var patterns []string
	var rawIgnore []byte
	var err error
	if ref != "" {
		rawIgnore, err = gitCmdBytes(repoDir, "show", ref+":.rollupignore")
	}
	if ref == "" || err != nil {
		rawIgnore, err = os.ReadFile(filepath.Join(repoDir, ".rollupignore"))
	}
	if err == nil {
		for _, line := range strings.Split(string(rawIgnore), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			patterns = append(patterns, line)
		}
	}
	patterns = append(patterns, splitCSV(extraCSV)...)
	return patterns
}

func matchesPattern(path, pat string) bool {
	if strings.HasSuffix(pat, "/") {
		prefix := strings.TrimSuffix(pat, "/")
		if strings.HasPrefix(path, prefix+"/") || path == prefix || strings.Contains(path, "/"+prefix+"/") {
			return true
		}
	}
	matched, err := filepath.Match(pat, filepath.Base(path))
	if err == nil && matched {
		return true
	}
	matched, err = filepath.Match(pat, path)
	if err == nil && matched {
		return true
	}
	return false
}

func shouldExclude(relPath string, ignorePatterns []string, noDefaultExcludes bool) bool {
	base := filepath.Base(relPath)
	if base == "package-lock.json" || base == "Cargo.lock" || base == "flake.lock" {
		return true
	}
	clean := filepath.ToSlash(relPath)
	if strings.HasPrefix(clean, "dist-newstyle/") || strings.Contains(clean, "/dist-newstyle/") {
		return true
	}
	if strings.HasPrefix(clean, "ref/pages/") || strings.Contains(clean, "/ref/pages/") {
		return true
	}
	if strings.Contains(clean, ".log") {
		return true
	}
	ext := filepath.Ext(clean)
	switch ext {
	case ".patch", ".hi", ".lock", ".o", ".tix", ".mix":
		return true
	}
	if !noDefaultExcludes {
		if strings.HasSuffix(base, ".min.js") || strings.HasSuffix(base, ".min.css") ||
			strings.HasSuffix(base, ".run.xml") {
			return true
		}
		switch ext {
		case ".aux", ".toc", ".fls", ".fdb_latexmk", ".bbl", ".blg", ".bcf":
			return true
		}
		if strings.HasPrefix(clean, "docs/transcripts/") || strings.Contains(clean, "/docs/transcripts/") {
			return true
		}
		if strings.HasPrefix(clean, "corpus/") || strings.Contains(clean, "/corpus/") {
			return true
		}
		if strings.HasPrefix(clean, "CMakeFiles/") || strings.Contains(clean, "/CMakeFiles/") {
			return true
		}
	}
	for _, pat := range ignorePatterns {
		if matchesPattern(clean, pat) {
			return true
		}
	}
	return false
}

func isBinaryOrInvalidUTF8(data []byte) bool {
	if bytes.IndexByte(data, 0) != -1 {
		return true
	}
	return !utf8.Valid(data)
}

func isArchCandidate(relPath string) bool {
	base := filepath.Base(relPath)
	clean := filepath.ToSlash(relPath)
	if strings.HasPrefix(base, "cabal.project") || strings.HasSuffix(base, ".cabal") {
		return true
	}
	if base == "README.md" || base == "PLAN.md" || base == "STATE.md" ||
		base == "ROADMAP.md" || base == "LICENSES-THIRD-PARTY.md" || base == "CREDITS.md" {
		return true
	}
	if strings.HasPrefix(clean, "docs/") && strings.HasSuffix(base, ".md") {
		return true
	}
	if strings.HasSuffix(base, ".dhall") || strings.HasSuffix(base, ".hs") ||
		strings.HasSuffix(base, ".hsig") || strings.HasSuffix(base, ".h") {
		return true
	}
	return false
}

func extractArchSummaryHS(content string) string {
	lines := strings.Split(content, "\n")
	var result []string
	inModuleHeader := false
	inBlockDoc := false
	inDecl := false

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if strings.HasPrefix(trimmed, "{-|") || strings.HasPrefix(trimmed, "{- |") {
			inBlockDoc = true
			result = append(result, line)
			if strings.Contains(line, "-}") {
				inBlockDoc = false
			}
			continue
		}
		if inBlockDoc {
			result = append(result, line)
			if strings.Contains(line, "-}") {
				inBlockDoc = false
			}
			continue
		}

		if strings.HasPrefix(line, "module ") {
			inModuleHeader = true
			result = append(result, line)
			if strings.Contains(line, " where") {
				inModuleHeader = false
			}
			continue
		}
		if inModuleHeader {
			result = append(result, line)
			if strings.Contains(line, " where") || trimmed == "where" {
				inModuleHeader = false
			}
			continue
		}

		if strings.HasPrefix(trimmed, "-- |") || strings.HasPrefix(trimmed, "-- ^") || strings.HasPrefix(trimmed, "-- *") {
			result = append(result, line)
			continue
		}

		if len(line) > 0 && (line[0] != ' ' && line[0] != '\t') {
			if strings.HasPrefix(line, "data ") ||
				strings.HasPrefix(line, "newtype ") ||
				strings.HasPrefix(line, "type ") ||
				strings.HasPrefix(line, "class ") ||
				strings.HasPrefix(line, "instance ") ||
				strings.HasPrefix(line, "type family ") ||
				strings.HasPrefix(line, "data family ") {
				inDecl = true
				result = append(result, line)
				continue
			}
			if strings.Contains(line, " :: ") {
				inDecl = true
				result = append(result, line)
				continue
			}
			inDecl = false
		} else if inDecl && len(trimmed) > 0 {
			result = append(result, line)
		}
	}
	return strings.Join(result, "\n")
}

func fenceLang(relPath string) string {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(relPath), "."))
	switch ext {
	case "hs", "hsig":
		return "haskell"
	case "md":
		return "markdown"
	case "rs":
		return "rust"
	case "py":
		return "python"
	case "sh":
		return "bash"
	case "h":
		return "c"
	case "ml", "mli":
		return "ocaml"
	case "scm", "sld":
		return "scheme"
	case "f90", "f95":
		return "fortran"
	case "v":
		return "coq"
	case "s":
		return "asm"
	case "ltx", "tex":
		return "latex"
	case "idr":
		return "idris"
	case "kk":
		return "koka"
	case "txt":
		return "text"
	default:
		return ext
	}
}

func renderFileBlock(path, content, langOverride string) fileBlock {
	lang := langOverride
	if lang == "" {
		lang = fenceLang(path)
	}
	body := strings.TrimRight(content, "\n")
	fence := "```"
	if strings.Contains(body, "```") {
		fence = "````"
	}
	rendered := fmt.Sprintf("## File: %s\n\n%s%s\n%s\n%s\n\n", path, fence, lang, body, fence)
	return fileBlock{
		path:     path,
		rendered: rendered,
		runes:    utf8.RuneCountInString(rendered),
		words:    countWords(rendered),
	}
}

func entriesToBlocks(entries []fileEntry, maxChars, maxWords int, autoShard bool) []fileBlock {
	var blocks []fileBlock
	singleCharCap := 0
	if maxChars > 12288 {
		singleCharCap = maxChars - 8192
	}
	singleWordCap := 0
	if maxWords > 2048 {
		singleWordCap = maxWords - 1024
	}

	for _, entry := range entries {
		blk := renderFileBlock(entry.path, entry.content, entry.langOverride)
		oversizedChars := singleCharCap > 0 && blk.runes > singleCharCap
		oversizedWords := singleWordCap > 0 && blk.words > singleWordCap
		if !autoShard || (!oversizedChars && !oversizedWords) {
			blocks = append(blocks, blk)
			continue
		}

		lines := strings.Split(entry.content, "\n")
		var rawChunks []string
		var cur strings.Builder
		curRunes := 0
		curWords := 0
		charBudget := 0
		if singleCharCap > 0 {
			charBudget = singleCharCap - 256
		}
		wordBudget := 0
		if singleWordCap > 0 {
			wordBudget = singleWordCap - 64
		}

		for _, line := range lines {
			lr := utf8.RuneCountInString(line) + 1
			lw := countWords(line)
			exceedsChars := charBudget > 0 && curRunes+lr > charBudget
			exceedsWords := wordBudget > 0 && curWords+lw > wordBudget
			if (curRunes > 0 || curWords > 0) && (exceedsChars || exceedsWords) {
				rawChunks = append(rawChunks, cur.String())
				cur.Reset()
				curRunes = 0
				curWords = 0
			}
			cur.WriteString(line)
			cur.WriteByte('\n')
			curRunes += lr
			curWords += lw
		}
		if cur.Len() > 0 {
			rawChunks = append(rawChunks, cur.String())
		}
		fmt.Fprintf(os.Stderr, "[nadiverse-rollup] note: oversized file %s (%d runes, %d words) split into %d chunks\n",
			entry.path, blk.runes, blk.words, len(rawChunks))
		for ci, chunk := range rawChunks {
			label := fmt.Sprintf("%s [chunk %d/%d]", entry.path, ci+1, len(rawChunks))
			lang := entry.langOverride
			if lang == "" {
				lang = fenceLang(entry.path)
			}
			blocks = append(blocks, renderFileBlock(label, chunk, lang))
		}
	}
	return blocks
}

func renderCrossShardTOC(baseKey string, groups [][]fileBlock) string {
	var sb strings.Builder
	sb.WriteString("## Cross-Shard Table of Contents\n\n")
	sb.WriteString(fmt.Sprintf("This digest is split across **%d shards** (`part-01` .. `part-%02d`) using whole-file directory-grouped bin-packing.\n\n",
		len(groups), len(groups)))
	sb.WriteString("| Shard | Key | Files | Body Runes | Body Words | First File | Last File |\n")
	sb.WriteString("| :--- | :--- | ---: | ---: | ---: | :--- | :--- |\n")
	for i, g := range groups {
		sumRunes := 0
		sumWords := 0
		for _, b := range g {
			sumRunes += b.runes
			sumWords += b.words
		}
		first, last := "(index-only)", "(index-only)"
		if len(g) > 0 {
			first = "`" + g[0].path + "`"
			last = "`" + g[len(g)-1].path + "`"
		}
		sb.WriteString(fmt.Sprintf("| `part-%02d` | `%s:part-%02d` | %d | %d | %d | %s | %s |\n",
			i+1, baseKey, i+1, len(g), sumRunes, sumWords, first, last))
	}
	sb.WriteString("\n### Master File Index (`filepath -> shard`)\n\n```\n")
	for i, g := range groups {
		for _, b := range g {
			sb.WriteString(fmt.Sprintf("part-%02d  %8d runes  %7d words  %s\n", i+1, b.runes, b.words, b.path))
		}
	}
	sb.WriteString("```\n\n")
	return sb.String()
}

func renderShardMarkdown(
	cfg RollupConfig,
	meta RollupMeta,
	shardIdx, totalShards int,
	blocks []fileBlock,
	crossTOC string,
) string {
	var sb strings.Builder
	if totalShards > 1 {
		sb.WriteString(fmt.Sprintf("# Monorepo Digest: %s (Part %02d/%02d)\n\n", cfg.Key, shardIdx, totalShards))
	} else {
		sb.WriteString(fmt.Sprintf("# Monorepo Digest: %s\n\n", cfg.Key))
	}
	sb.WriteString(fmt.Sprintf("- **Repository:** `%s`\n", meta.RepoName))
	sb.WriteString(fmt.Sprintf("- **Mode:** `%s`\n", meta.Mode))
	if meta.Ref != "" {
		sb.WriteString(fmt.Sprintf("- **Ref:** `%s`\n", meta.Ref))
	}
	if meta.Base != "" {
		if meta.MergeBaseSHA != "" {
			sb.WriteString(fmt.Sprintf("- **Base:** `%s` (merge-base `%s`)\n", meta.Base, meta.MergeBaseSHA))
		} else {
			sb.WriteString(fmt.Sprintf("- **Default Base:** `%s`\n", meta.Base))
		}
	}
	if meta.Prefix != "" {
		sb.WriteString(fmt.Sprintf("- **Prefix:** `%s`\n", meta.Prefix))
	}
	sb.WriteString(fmt.Sprintf("- **Commit:** `%s` (%s)\n", meta.CommitSHA, meta.CommitTime))
	sb.WriteString(fmt.Sprintf("- **Tier:** `%s`\n", cfg.Tier))
	if totalShards > 1 {
		sb.WriteString(fmt.Sprintf("- **Shard:** `%02d / %02d` (Master Cross-Shard TOC is in `part-01`)\n", shardIdx, totalShards))
	}
	sb.WriteString(fmt.Sprintf("- **Files in This Digest:** %d\n\n", len(blocks)))

	if crossTOC != "" {
		sb.WriteString(crossTOC)
	}

	sb.WriteString("## Tracked File Tree (This Shard)\n\n```\n")
	for _, b := range blocks {
		sb.WriteString(b.path + "\n")
	}
	sb.WriteString("```\n\n")

	for _, b := range blocks {
		sb.WriteString(b.rendered)
	}
	return sb.String()
}

func withinCaps(runes, words, maxChars, maxWords int) bool {
	if maxChars > 0 && runes > maxChars {
		return false
	}
	if maxWords > 0 && words > maxWords {
		return false
	}
	return true
}

func packBlocksIntoShards(
	cfg RollupConfig,
	meta RollupMeta,
	blocks []fileBlock,
) []RollupShard {
	if !cfg.AutoShard || (cfg.MaxChars <= 0 && cfg.MaxWords <= 0) {
		md := renderShardMarkdown(cfg, meta, 1, 1, blocks, "")
		return []RollupShard{makeShard(cfg, 1, 1, meta.CommitSHA, blocks, md)}
	}

	singleMD := renderShardMarkdown(cfg, meta, 1, 1, blocks, "")
	if withinCaps(utf8.RuneCountInString(singleMD), countWords(singleMD), cfg.MaxChars, cfg.MaxWords) {
		return []RollupShard{makeShard(cfg, 1, 1, meta.CommitSHA, blocks, singleMD)}
	}

	const baseHeaderRuneMargin = 1280
	const baseHeaderWordMargin = 200
	tocRuneReserve := 0
	tocWordReserve := 0
	var groups [][]fileBlock
	var crossTOC string

	for pass := 0; pass < 8; pass++ {
		groups = nil
		var cur []fileBlock
		curBodyRunes, curTreeRunes := 0, 0
		curBodyWords, curTreeWords := 0, 0

		flush := func() {
			if len(cur) > 0 {
				groups = append(groups, cur)
				cur = nil
				curBodyRunes, curTreeRunes = 0, 0
				curBodyWords, curTreeWords = 0, 0
			}
		}

		indexOnlyFirst := (cfg.MaxChars > 0 && tocRuneReserve > 0 && tocRuneReserve+baseHeaderRuneMargin >= cfg.MaxChars-4096) ||
			(cfg.MaxWords > 0 && tocWordReserve > 0 && tocWordReserve+baseHeaderWordMargin >= cfg.MaxWords-512)
		if indexOnlyFirst {
			groups = append(groups, nil)
		}

		for _, b := range blocks {
			extraRunes, extraWords := 0, 0
			if len(groups) == 0 && !indexOnlyFirst {
				extraRunes = tocRuneReserve
				extraWords = tocWordReserve
			}
			treeAddRunes := utf8.RuneCountInString(b.path) + 1
			treeAddWords := countWords(b.path)
			if treeAddWords == 0 {
				treeAddWords = 1
			}
			projRunes := baseHeaderRuneMargin + extraRunes + curTreeRunes + treeAddRunes + curBodyRunes + b.runes
			projWords := baseHeaderWordMargin + extraWords + curTreeWords + treeAddWords + curBodyWords + b.words
			if len(cur) > 0 && !withinCaps(projRunes, projWords, cfg.MaxChars, cfg.MaxWords) {
				flush()
			}
			cur = append(cur, b)
			curBodyRunes += b.runes
			curTreeRunes += treeAddRunes
			curBodyWords += b.words
			curTreeWords += treeAddWords
		}
		flush()

		if len(groups) == 0 {
			groups = [][]fileBlock{nil}
		}

		crossTOC = renderCrossShardTOC(cfg.Key, groups)
		actualTOCRunes := utf8.RuneCountInString(crossTOC)
		actualTOCWords := countWords(crossTOC)
		md0 := renderShardMarkdown(cfg, meta, 1, len(groups), groups[0], crossTOC)
		md0Runes := utf8.RuneCountInString(md0)
		md0Words := countWords(md0)

		if actualTOCRunes <= tocRuneReserve && actualTOCWords <= tocWordReserve &&
			withinCaps(md0Runes, md0Words, cfg.MaxChars, cfg.MaxWords) {
			break
		}
		if actualTOCRunes+512 > tocRuneReserve {
			tocRuneReserve = actualTOCRunes + 512
		}
		if cfg.MaxChars > 0 && md0Runes > cfg.MaxChars {
			tocRuneReserve += (md0Runes - cfg.MaxChars) + 512
		}
		if actualTOCWords+128 > tocWordReserve {
			tocWordReserve = actualTOCWords + 128
		}
		if cfg.MaxWords > 0 && md0Words > cfg.MaxWords {
			tocWordReserve += (md0Words - cfg.MaxWords) + 128
		}
	}

	total := len(groups)
	shards := make([]RollupShard, 0, total)
	for i, g := range groups {
		toc := ""
		if i == 0 && total > 1 {
			toc = crossTOC
		}
		md := renderShardMarkdown(cfg, meta, i+1, total, g, toc)
		shards = append(shards, makeShard(cfg, i+1, total, meta.CommitSHA, g, md))
	}
	return shards
}

func makeShard(cfg RollupConfig, idx, total int, commitSHA string, blocks []fileBlock, md string) RollupShard {
	key := cfg.Key
	title := cfg.DocTitle
	if total > 1 {
		key = fmt.Sprintf("%s:part-%02d", cfg.Key, idx)
		title = fmt.Sprintf("%s [part %02d/%02d]", cfg.DocTitle, idx, total)
	}
	return RollupShard{
		Index:    idx,
		Total:    total,
		Key:      key,
		Title:    title,
		Markdown: md,
		Blocks:   blocks,
		Stats: RollupStats{
			CommitSHA: commitSHA,
			Files:     len(blocks),
			Bytes:     len(md),
			Runes:     utf8.RuneCountInString(md),
			Words:     countWords(md),
		},
	}
}

func filterAndTransformContent(cfg RollupConfig, relPath string, data []byte) (string, bool) {
	if isBinaryOrInvalidUTF8(data) {
		return "", false
	}
	strContent := string(data)
	if cfg.Tier == "arch" {
		if !isArchCandidate(relPath) {
			return "", false
		}
		if strings.HasSuffix(relPath, ".dhall") && len(data) > 50000 {
			return "", false
		}
		if strings.HasSuffix(relPath, ".hs") {
			strContent = extractArchSummaryHS(strContent)
		}
	}
	return strContent, true
}

func collectWorktreeEntries(cfg RollupConfig, prefix string, ignorePatterns []string) ([]fileEntry, error) {
	lsArgs := []string{"ls-files", "-z"}
	if prefix != "" {
		lsArgs = append(lsArgs, "--", prefix)
	}
	lsOut, err := gitCmdBytes(cfg.RepoDir, lsArgs...)
	if err != nil {
		return nil, fmt.Errorf("git ls-files: %w", err)
	}

	var trackedFiles []string
	for _, rec := range bytes.Split(lsOut, []byte{0}) {
		if len(rec) > 0 {
			trackedFiles = append(trackedFiles, string(rec))
		}
	}
	sort.Strings(trackedFiles)

	var entries []fileEntry
	for _, f := range trackedFiles {
		if shouldExclude(f, ignorePatterns, cfg.NoDefaultExcludes) {
			continue
		}
		fullPath := filepath.Join(cfg.RepoDir, f)
		fi, err := os.Stat(fullPath)
		if err != nil || fi.IsDir() {
			continue
		}
		data, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}
		if content, ok := filterAndTransformContent(cfg, f, data); ok {
			entries = append(entries, fileEntry{path: f, content: content})
		}
	}
	return entries, nil
}

func collectRefSnapshotEntries(cfg RollupConfig, ref, prefix string, ignorePatterns []string) ([]fileEntry, error) {
	lsArgs := []string{"ls-tree", "-r", "-z", ref}
	if prefix != "" {
		lsArgs = append(lsArgs, "--", prefix)
	}
	lsOut, err := gitCmdBytes(cfg.RepoDir, lsArgs...)
	if err != nil {
		return nil, fmt.Errorf("git ls-tree %s: %w", ref, err)
	}

	type treeBlob struct {
		path string
		oid  string
	}
	var blobs []treeBlob
	for _, rec := range bytes.Split(lsOut, []byte{0}) {
		if len(rec) == 0 {
			continue
		}
		metaBytes, pathBytes, ok := bytes.Cut(rec, []byte{'\t'})
		if !ok {
			continue
		}
		fields := strings.Fields(string(metaBytes))
		if len(fields) < 3 || fields[1] != "blob" {
			continue
		}
		blobs = append(blobs, treeBlob{
			path: string(pathBytes),
			oid:  fields[2],
		})
	}
	sort.Slice(blobs, func(i, j int) bool { return blobs[i].path < blobs[j].path })

	var entries []fileEntry
	for _, b := range blobs {
		if shouldExclude(b.path, ignorePatterns, cfg.NoDefaultExcludes) {
			continue
		}
		data, err := gitCmdBytes(cfg.RepoDir, "cat-file", "blob", b.oid)
		if err != nil {
			continue
		}
		if content, ok := filterAndTransformContent(cfg, b.path, data); ok {
			entries = append(entries, fileEntry{path: b.path, content: content})
		}
	}
	return entries, nil
}

type deltaChange struct {
	status  string
	oldPath string
	newPath string
}

func parseNameStatusZ(raw []byte) []deltaChange {
	tokens := bytes.Split(raw, []byte{0})
	var out []deltaChange
	for i := 0; i < len(tokens); {
		st := string(tokens[i])
		if st == "" {
			i++
			continue
		}
		if strings.HasPrefix(st, "R") || strings.HasPrefix(st, "C") {
			if i+2 >= len(tokens) {
				break
			}
			out = append(out, deltaChange{
				status:  st,
				oldPath: string(tokens[i+1]),
				newPath: string(tokens[i+2]),
			})
			i += 3
		} else {
			if i+1 >= len(tokens) {
				break
			}
			p := string(tokens[i+1])
			out = append(out, deltaChange{
				status:  st,
				oldPath: p,
				newPath: p,
			})
			i += 2
		}
	}
	return out
}

func collectBranchDeltaEntries(cfg RollupConfig, mergeBaseFull, ref, prefix, labelPrefix string, ignorePatterns []string) ([]fileEntry, error) {
	var entries []fileEntry
	prefixLabel := func(s string) string {
		if labelPrefix == "" {
			return s
		}
		return labelPrefix + " " + s
	}

	logArgs := []string{"log", "--stat", "--no-color", mergeBaseFull + ".." + ref, "--"}
	if prefix != "" {
		logArgs = append(logArgs, prefix)
	}
	logOut, err := gitCmd(cfg.RepoDir, logArgs...)
	if err != nil {
		return nil, fmt.Errorf("git log %s..%s: %w", mergeBaseFull, ref, err)
	}
	if strings.TrimSpace(logOut) == "" {
		logOut = fmt.Sprintf("(no commits between %s and %s)\n", shortSHA(mergeBaseFull), ref)
	}
	entries = append(entries, fileEntry{
		path:         prefixLabel("(git)/branch-log.txt"),
		content:      logOut,
		langOverride: "text",
	})

	nsArgs := []string{"diff", "--name-status", "-z", "-M", "--no-ext-diff", "--no-textconv", mergeBaseFull, ref, "--"}
	if prefix != "" {
		nsArgs = append(nsArgs, prefix)
	}
	nsRaw, err := gitCmdBytes(cfg.RepoDir, nsArgs...)
	if err != nil {
		return nil, fmt.Errorf("git diff --name-status: %w", err)
	}
	changes := parseNameStatusZ(nsRaw)
	sort.Slice(changes, func(i, j int) bool { return changes[i].newPath < changes[j].newPath })

	ctxArg := fmt.Sprintf("-U%d", max(0, cfg.DiffContext))
	var deletedPaths []string

	for _, ch := range changes {
		if ch.status == "D" {
			if !shouldExclude(ch.oldPath, ignorePatterns, cfg.NoDefaultExcludes) {
				deletedPaths = append(deletedPaths, ch.oldPath)
			}
			continue
		}
		if shouldExclude(ch.newPath, ignorePatterns, cfg.NoDefaultExcludes) {
			continue
		}

		if ch.status == "A" || (cfg.DeltaFullModified && (ch.status == "M" || ch.status == "T")) {
			data, err := gitCmdBytes(cfg.RepoDir, "show", ref+":"+ch.newPath)
			if err != nil {
				continue
			}
			if content, ok := filterAndTransformContent(cfg, ch.newPath, data); ok {
				label := ch.newPath
				if ch.status == "A" {
					label = ch.newPath + " [added]"
				}
				entries = append(entries, fileEntry{
					path:         prefixLabel(label),
					content:      content,
					langOverride: fenceLang(ch.newPath),
				})
			}
			continue
		}

		if cfg.Tier == "arch" && !isArchCandidate(ch.newPath) {
			continue
		}
		diffArgs := []string{"diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", ctxArg, mergeBaseFull, ref, "--"}
		if ch.oldPath != ch.newPath {
			diffArgs = append(diffArgs, ch.oldPath, ch.newPath)
		} else {
			diffArgs = append(diffArgs, ch.newPath)
		}
		diffBytes, err := gitCmdBytes(cfg.RepoDir, diffArgs...)
		if err != nil || len(bytes.TrimSpace(diffBytes)) == 0 {
			continue
		}
		if isBinaryOrInvalidUTF8(diffBytes) {
			continue
		}
		label := ch.newPath + " [diff]"
		if ch.oldPath != ch.newPath {
			label = fmt.Sprintf("%s [renamed from %s, %s]", ch.newPath, ch.oldPath, ch.status)
		}
		entries = append(entries, fileEntry{
			path:         prefixLabel(label),
			content:      string(diffBytes),
			langOverride: "diff",
		})
	}

	if len(deletedPaths) > 0 {
		sort.Strings(deletedPaths)
		entries = append(entries, fileEntry{
			path:         prefixLabel("(git)/deleted-files.txt"),
			content:      strings.Join(deletedPaths, "\n") + "\n",
			langOverride: "text",
		})
	}
	return entries, nil
}

func buildRollupShards(cfg RollupConfig, repoName, prefix string) ([]RollupShard, RollupMeta, error) {
	targetRef := cfg.Ref
	if targetRef == "" {
		targetRef = "HEAD"
	}

	shaOut, err := gitCmd(cfg.RepoDir, "rev-parse", "--short=12", targetRef+"^{commit}")
	if err != nil {
		return nil, RollupMeta{}, fmt.Errorf("git rev-parse %s: %w", targetRef, err)
	}
	commitSHA := strings.TrimSpace(shaOut)

	timeOut, _ := gitCmd(cfg.RepoDir, "log", "-1", "--format=%cI", targetRef, "--")
	commitTime := strings.TrimSpace(timeOut)

	meta := RollupMeta{
		RepoName:   repoName,
		Prefix:     prefix,
		Ref:        cfg.Ref,
		Base:       cfg.Base,
		CommitSHA:  commitSHA,
		CommitTime: commitTime,
	}

	ignorePatterns := loadRollupIgnore(cfg.RepoDir, cfg.Ref, cfg.Exclude)

	var entries []fileEntry
	switch {
	case cfg.AllBranches:
		meta.Mode = "all-branches-delta"
		plan, err := discoverRelevantBranches(cfg)
		if err != nil {
			return nil, RollupMeta{}, err
		}
		meta.Base = plan.DefaultBase
		entries = append(entries, fileEntry{
			path:         "(git)/branches-summary.md",
			content:      renderBranchesSummaryMD(repoName, plan),
			langOverride: "markdown",
		})
		for _, br := range plan.Selected {
			lbl := fmt.Sprintf("[branch:%s vs %s]", br.Name, br.BaseRef)
			brEntries, err := collectBranchDeltaEntries(cfg, br.MergeBaseFull, br.Name, prefix, lbl, ignorePatterns)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[nadiverse-rollup] warn: skipping branch %s: %v\n", br.Name, err)
				continue
			}
			entries = append(entries, brEntries...)
		}
	case cfg.Base != "":
		meta.Mode = "branch-delta"
		if meta.Ref == "" {
			meta.Ref = "HEAD"
		}
		resolvedBase, err := resolveDefaultBase(cfg.RepoDir, cfg.Base)
		if err != nil {
			return nil, RollupMeta{}, err
		}
		meta.Base = resolvedBase
		mbOut, err := gitCmd(cfg.RepoDir, "merge-base", resolvedBase, targetRef)
		if err != nil {
			return nil, RollupMeta{}, fmt.Errorf("git merge-base %s %s: %w", resolvedBase, targetRef, err)
		}
		mergeBaseFull := strings.TrimSpace(mbOut)
		meta.MergeBaseSHA = shortSHA(mergeBaseFull)
		entries, err = collectBranchDeltaEntries(cfg, mergeBaseFull, targetRef, prefix, "", ignorePatterns)
		if err != nil {
			return nil, RollupMeta{}, err
		}
	case cfg.Ref != "":
		meta.Mode = "branch-snapshot"
		entries, err = collectRefSnapshotEntries(cfg, cfg.Ref, prefix, ignorePatterns)
		if err != nil {
			return nil, RollupMeta{}, err
		}
	default:
		meta.Mode = "worktree"
		entries, err = collectWorktreeEntries(cfg, prefix, ignorePatterns)
		if err != nil {
			return nil, RollupMeta{}, err
		}
	}

	blocks := entriesToBlocks(entries, cfg.MaxChars, cfg.MaxWords, cfg.AutoShard)
	return packBlocksIntoShards(cfg, meta, blocks), meta, nil
}

func resolveAccessToken(client *http.Client, tokenURL string) (string, error) {
	if token := os.Getenv("NADIVERSE_GDRIVE_TOKEN"); token != "" {
		return token, nil
	}
	clientID := os.Getenv("NADIVERSE_GDRIVE_CLIENT_ID")
	clientSecret := os.Getenv("NADIVERSE_GDRIVE_CLIENT_SECRET")
	refreshToken := os.Getenv("NADIVERSE_GDRIVE_REFRESH_TOKEN")
	if clientID == "" || clientSecret == "" || refreshToken == "" {
		return "", errors.New("neither NADIVERSE_GDRIVE_TOKEN nor (NADIVERSE_GDRIVE_CLIENT_ID, NADIVERSE_GDRIVE_CLIENT_SECRET, NADIVERSE_GDRIVE_REFRESH_TOKEN) are set")
	}

	form := url.Values{
		"client_id":     {clientID},
		"client_secret": {clientSecret},
		"refresh_token": {refreshToken},
		"grant_type":    {"refresh_token"},
	}

	req, err := http.NewRequest("POST", tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("token exchange request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("token endpoint returned status %d: %s", resp.StatusCode, string(b))
	}

	var tr struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return "", fmt.Errorf("decoding token response: %w", err)
	}
	if tr.AccessToken == "" {
		return "", errors.New("empty access_token received from token endpoint")
	}
	return tr.AccessToken, nil
}

func upsertGoogleDoc(client *http.Client, cfg RollupConfig, mapKey, docTitle, token, md string) (string, bool, error) {
	mapData := make(map[string]string)
	if data, err := os.ReadFile(cfg.MapFile); err == nil {
		_ = json.Unmarshal(data, &mapData)
	}

	docID := mapData[mapKey]
	if docID != "" {
		patchURL := fmt.Sprintf("%s/files/%s?uploadType=media", strings.TrimRight(cfg.UploadBaseURL, "/"), docID)
		req, err := http.NewRequest("PATCH", patchURL, strings.NewReader(md))
		if err != nil {
			return "", false, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "text/markdown; charset=utf-8")

		resp, err := client.Do(req)
		if err != nil {
			return "", false, fmt.Errorf("drive patch request: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			b, _ := io.ReadAll(resp.Body)
			return "", false, fmt.Errorf("drive patch returned %d: %s", resp.StatusCode, string(b))
		}
		return docID, false, nil
	}

	if !cfg.CreateMissing {
		return "", false, fmt.Errorf("no doc_id mapped for key %q in %s; pass -create-missing to create one", mapKey, cfg.MapFile)
	}

	createURL := fmt.Sprintf("%s/files?uploadType=multipart", strings.TrimRight(cfg.UploadBaseURL, "/"))
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)

	metaH := make(textproto.MIMEHeader)
	metaH.Set("Content-Type", "application/json; charset=UTF-8")
	metaPart, err := mw.CreatePart(metaH)
	if err != nil {
		return "", false, err
	}
	metaJSON, _ := json.Marshal(map[string]string{
		"name":     docTitle,
		"mimeType": "application/vnd.google-apps.document",
	})
	if _, err := metaPart.Write(metaJSON); err != nil {
		return "", false, err
	}

	mediaH := make(textproto.MIMEHeader)
	mediaH.Set("Content-Type", "text/markdown; charset=utf-8")
	mediaPart, err := mw.CreatePart(mediaH)
	if err != nil {
		return "", false, err
	}
	if _, err := mediaPart.Write([]byte(md)); err != nil {
		return "", false, err
	}

	if err := mw.Close(); err != nil {
		return "", false, err
	}

	req, err := http.NewRequest("POST", createURL, &body)
	if err != nil {
		return "", false, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", fmt.Sprintf("multipart/related; boundary=%s", mw.Boundary()))

	resp, err := client.Do(req)
	if err != nil {
		return "", false, fmt.Errorf("drive create request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return "", false, fmt.Errorf("drive create returned %d: %s", resp.StatusCode, string(b))
	}

	var cr struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		return "", false, fmt.Errorf("decoding create response: %w", err)
	}
	if cr.ID == "" {
		return "", false, errors.New("drive create returned empty file ID")
	}

	mapData[mapKey] = cr.ID
	if err := os.MkdirAll(filepath.Dir(cfg.MapFile), 0o755); err == nil {
		if outBytes, err := json.MarshalIndent(mapData, "", "  "); err == nil {
			_ = os.WriteFile(cfg.MapFile, outBytes, 0o644)
		}
	}

	return cr.ID, true, nil
}
