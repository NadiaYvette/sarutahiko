// nadiverse-rollup: Roll git repositories into structured Markdown digests and
// update linked Google Docs in place for Gemini Notebook auto-sync.
// Supports whole-file directory-grouped auto-sharding with a Cross-Shard TOC
// in part-01 so large repos stay strictly beneath Google Docs' 1.02M char cap.
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
	"unicode/utf8"
)

type RollupConfig struct {
	RepoDir       string
	Prefix        string
	Key           string
	DocTitle      string
	Tier          string // "arch" or "full"
	MaxChars      int
	AutoShard     bool
	Exclude       string // comma-separated extra exclude patterns
	OutFile       string
	MapFile       string
	DryRun        bool
	CreateMissing bool
	UploadBaseURL string
	TokenURL      string
}

type RollupStats struct {
	CommitSHA string
	Files     int
	Bytes     int
	Runes     int
	Words     int
}

type fileEntry struct {
	path    string
	content string
}

type fileBlock struct {
	path     string // original relative path (or path + " [chunk i/n]" if oversized)
	rendered string
	runes    int
}

type RollupShard struct {
	Index    int // 1-based
	Total    int
	Key      string
	Title    string
	Markdown string
	Stats    RollupStats
	Blocks   []fileBlock
}

func main() {
	cfg := RollupConfig{}
	flag.StringVar(&cfg.RepoDir, "repo", ".", "Path to git repository")
	flag.StringVar(&cfg.Prefix, "prefix", "", "Optional tracked path prefix (e.g. packages/kogaki)")
	flag.StringVar(&cfg.Key, "key", "", "Lookup key in -map-file (default: repo or repo:prefix)")
	flag.StringVar(&cfg.DocTitle, "title", "", "Google Doc title when creating a new doc")
	flag.StringVar(&cfg.Tier, "tier", "arch", "Digest tier: 'arch' (interfaces+docs) or 'full'")
	flag.IntVar(&cfg.MaxChars, "max-chars", 800000, "Max Unicode character count per doc (Google Docs cap ~1.02M)")
	flag.BoolVar(&cfg.AutoShard, "auto-shard", true, "Automatically bin-pack into whole-file part-01..part-NN docs when exceeding -max-chars")
	flag.StringVar(&cfg.Exclude, "exclude", "", "Comma-separated extra exclude patterns (e.g. 'examples/,witnesses/,scripts/tasks/')")
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

func runRollup(cfg RollupConfig) error {
	absRepo, err := filepath.Abs(cfg.RepoDir)
	if err != nil {
		return err
	}
	cfg.RepoDir = absRepo
	repoName := filepath.Base(absRepo)
	cleanPrefix := strings.Trim(filepath.ToSlash(cfg.Prefix), "/")
	if cfg.Key == "" {
		if cleanPrefix == "" {
			cfg.Key = repoName
		} else {
			cfg.Key = repoName + ":" + cleanPrefix
		}
	}
	if cfg.DocTitle == "" {
		cfg.DocTitle = fmt.Sprintf("Rollup: %s (%s)", cfg.Key, cfg.Tier)
	}

	shards, err := buildRollupShards(cfg, repoName, cleanPrefix)
	if err != nil {
		return err
	}

	totalFiles, totalRunes, totalWords := 0, 0, 0
	for _, sh := range shards {
		totalFiles += sh.Stats.Files
		totalRunes += sh.Stats.Runes
		totalWords += sh.Stats.Words
		fmt.Printf("[nadiverse-rollup] key=%s part=%02d/%02d tier=%s commit=%s files=%d runes=%d words=%d bytes=%d\n",
			sh.Key, sh.Index, sh.Total, cfg.Tier, sh.Stats.CommitSHA, sh.Stats.Files, sh.Stats.Runes, sh.Stats.Words, sh.Stats.Bytes)

		if cfg.MaxChars > 0 && sh.Stats.Runes > cfg.MaxChars {
			return fmt.Errorf("shard %s (%02d/%02d) has %d characters, exceeding -max-chars=%d",
				sh.Key, sh.Index, sh.Total, sh.Stats.Runes, cfg.MaxChars)
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

func gitCmd(repoDir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = repoDir
	var out bytes.Buffer
	var errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(errOut.String()))
	}
	return out.String(), nil
}

func loadRollupIgnore(repoDir string, extraCSV string) []string {
	var patterns []string
	ignorePath := filepath.Join(repoDir, ".rollupignore")
	if data, err := os.ReadFile(ignorePath); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			patterns = append(patterns, line)
		}
	}
	if extraCSV != "" {
		for _, part := range strings.Split(extraCSV, ",") {
			p := strings.TrimSpace(part)
			if p != "" {
				patterns = append(patterns, p)
			}
		}
	}
	return patterns
}

func matchesPattern(path, pat string) bool {
	if strings.HasSuffix(pat, "/") {
		prefix := strings.TrimSuffix(pat, "/")
		if strings.HasPrefix(path, prefix+"/") || path == prefix {
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

func shouldExclude(relPath string, ignorePatterns []string) bool {
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

// extractArchSummaryHS extracts module header, export list, docstrings, and
// top-level data/newtype/type/class/family declarations from Haskell sources.
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
	default:
		return ext
	}
}

func renderFileBlock(path, content string) fileBlock {
	lang := fenceLang(path)
	body := strings.TrimRight(content, "\n")
	// Use a 4-backtick fence if the file itself contains triple backticks (e.g. Markdown docs).
	fence := "```"
	if strings.Contains(body, "```") {
		fence = "````"
	}
	rendered := fmt.Sprintf("## File: %s\n\n%s%s\n%s\n%s\n\n", path, fence, lang, body, fence)
	return fileBlock{
		path:     path,
		rendered: rendered,
		runes:    utf8.RuneCountInString(rendered),
	}
}

func entriesToBlocks(entries []fileEntry, maxChars int, autoShard bool) []fileBlock {
	var blocks []fileBlock
	// Leave headroom for shard header/TOC; only split a single file if it cannot fit alone.
	singleFileCap := maxChars - 8192
	for _, entry := range entries {
		blk := renderFileBlock(entry.path, entry.content)
		if !autoShard || maxChars <= 0 || singleFileCap <= 4096 || blk.runes <= singleFileCap {
			blocks = append(blocks, blk)
			continue
		}
		// Oversized single file: split cleanly on line boundaries.
		lines := strings.Split(entry.content, "\n")
		var rawChunks []string
		var cur strings.Builder
		curRunes := 0
		chunkBudget := singleFileCap - 256
		for _, line := range lines {
			lr := utf8.RuneCountInString(line) + 1
			if curRunes > 0 && curRunes+lr > chunkBudget {
				rawChunks = append(rawChunks, cur.String())
				cur.Reset()
				curRunes = 0
			}
			cur.WriteString(line)
			cur.WriteByte('\n')
			curRunes += lr
		}
		if cur.Len() > 0 {
			rawChunks = append(rawChunks, cur.String())
		}
		fmt.Fprintf(os.Stderr, "[nadiverse-rollup] note: oversized file %s (%d runes) split into %d chunks\n",
			entry.path, blk.runes, len(rawChunks))
		for ci, chunk := range rawChunks {
			label := fmt.Sprintf("%s [chunk %d/%d]", entry.path, ci+1, len(rawChunks))
			blocks = append(blocks, renderFileBlock(label, chunk))
		}
	}
	return blocks
}

func renderCrossShardTOC(baseKey string, groups [][]fileBlock) string {
	var sb strings.Builder
	sb.WriteString("## Cross-Shard Table of Contents\n\n")
	sb.WriteString(fmt.Sprintf("This digest is split across **%d shards** (`part-01` .. `part-%02d`) using whole-file directory-grouped bin-packing.\n\n",
		len(groups), len(groups)))
	sb.WriteString("| Shard | Key | Files | Body Runes | First File | Last File |\n")
	sb.WriteString("| :--- | :--- | ---: | ---: | :--- | :--- |\n")
	for i, g := range groups {
		sumRunes := 0
		for _, b := range g {
			sumRunes += b.runes
		}
		first, last := "(index-only)", "(index-only)"
		if len(g) > 0 {
			first = "`" + g[0].path + "`"
			last = "`" + g[len(g)-1].path + "`"
		}
		sb.WriteString(fmt.Sprintf("| `part-%02d` | `%s:part-%02d` | %d | %d | %s | %s |\n",
			i+1, baseKey, i+1, len(g), sumRunes, first, last))
	}
	sb.WriteString("\n### Master File Index (`filepath -> shard`)\n\n```\n")
	for i, g := range groups {
		for _, b := range g {
			sb.WriteString(fmt.Sprintf("part-%02d  %8d runes  %s\n", i+1, b.runes, b.path))
		}
	}
	sb.WriteString("```\n\n")
	return sb.String()
}

func renderShardMarkdown(
	cfg RollupConfig,
	repoName, prefix, commitSHA, commitTime string,
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
	sb.WriteString(fmt.Sprintf("- **Repository:** `%s`\n", repoName))
	if prefix != "" {
		sb.WriteString(fmt.Sprintf("- **Prefix:** `%s`\n", prefix))
	}
	sb.WriteString(fmt.Sprintf("- **Commit:** `%s` (%s)\n", commitSHA, commitTime))
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

func packBlocksIntoShards(
	cfg RollupConfig,
	repoName, prefix, commitSHA, commitTime string,
	blocks []fileBlock,
) []RollupShard {
	if !cfg.AutoShard || cfg.MaxChars <= 0 {
		md := renderShardMarkdown(cfg, repoName, prefix, commitSHA, commitTime, 1, 1, blocks, "")
		return []RollupShard{makeShard(cfg, 1, 1, commitSHA, blocks, md)}
	}

	// Fast path: try single unsharded document first.
	singleMD := renderShardMarkdown(cfg, repoName, prefix, commitSHA, commitTime, 1, 1, blocks, "")
	if utf8.RuneCountInString(singleMD) <= cfg.MaxChars {
		return []RollupShard{makeShard(cfg, 1, 1, commitSHA, blocks, singleMD)}
	}

	// Multi-shard fixed-point packing: reserve space for Cross-Shard TOC in part-01.
	const baseHeaderMargin = 1024
	tocReserve := 0
	var groups [][]fileBlock
	var crossTOC string

	for pass := 0; pass < 6; pass++ {
		groups = nil
		var cur []fileBlock
		curBodyRunes := 0
		curTreeRunes := 0

		flush := func() {
			if len(cur) > 0 {
				groups = append(groups, cur)
				cur = nil
				curBodyRunes = 0
				curTreeRunes = 0
			}
		}

		// If the TOC alone nearly fills shard 0, emit shard 0 as a dedicated index-only shard.
		indexOnlyFirst := tocReserve > 0 && tocReserve+baseHeaderMargin >= cfg.MaxChars-4096
		if indexOnlyFirst {
			groups = append(groups, nil)
		}

		for _, b := range blocks {
			extra := 0
			if len(groups) == 0 && !indexOnlyFirst {
				extra = tocReserve
			}
			treeAdd := utf8.RuneCountInString(b.path) + 1
			projected := baseHeaderMargin + extra + curTreeRunes + treeAdd + curBodyRunes + b.runes
			if len(cur) > 0 && projected > cfg.MaxChars {
				flush()
			}
			cur = append(cur, b)
			curBodyRunes += b.runes
			curTreeRunes += treeAdd
		}
		flush()

		if len(groups) == 0 {
			groups = [][]fileBlock{nil}
		}

		crossTOC = renderCrossShardTOC(cfg.Key, groups)
		actualTOCRunes := utf8.RuneCountInString(crossTOC)
		md0 := renderShardMarkdown(cfg, repoName, prefix, commitSHA, commitTime, 1, len(groups), groups[0], crossTOC)
		if actualTOCRunes <= tocReserve && utf8.RuneCountInString(md0) <= cfg.MaxChars {
			break
		}
		tocReserve = actualTOCRunes + 512
	}

	total := len(groups)
	shards := make([]RollupShard, 0, total)
	for i, g := range groups {
		toc := ""
		if i == 0 && total > 1 {
			toc = crossTOC
		}
		md := renderShardMarkdown(cfg, repoName, prefix, commitSHA, commitTime, i+1, total, g, toc)
		shards = append(shards, makeShard(cfg, i+1, total, commitSHA, g, md))
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
			Words:     len(strings.Fields(md)),
		},
	}
}

func buildRollupShards(cfg RollupConfig, repoName, prefix string) ([]RollupShard, error) {
	shaOut, err := gitCmd(cfg.RepoDir, "rev-parse", "--short=12", "HEAD")
	if err != nil {
		return nil, fmt.Errorf("git rev-parse HEAD: %w", err)
	}
	commitSHA := strings.TrimSpace(shaOut)

	timeOut, _ := gitCmd(cfg.RepoDir, "log", "-1", "--format=%cI", "HEAD")
	commitTime := strings.TrimSpace(timeOut)

	lsArgs := []string{"ls-files"}
	if prefix != "" {
		lsArgs = append(lsArgs, "--", prefix)
	}
	lsOut, err := gitCmd(cfg.RepoDir, lsArgs...)
	if err != nil {
		return nil, fmt.Errorf("git ls-files: %w", err)
	}

	var trackedFiles []string
	for _, f := range strings.Split(strings.TrimSpace(lsOut), "\n") {
		f = strings.TrimSpace(f)
		if f != "" {
			trackedFiles = append(trackedFiles, f)
		}
	}
	// Lexicographic path sort naturally keeps sibling directory modules contiguous.
	sort.Strings(trackedFiles)

	ignorePatterns := loadRollupIgnore(cfg.RepoDir, cfg.Exclude)

	var entries []fileEntry
	for _, f := range trackedFiles {
		if shouldExclude(f, ignorePatterns) {
			continue
		}
		fullPath := filepath.Join(cfg.RepoDir, f)
		fi, err := os.Stat(fullPath)
		if err != nil || fi.IsDir() {
			continue
		}
		data, err := os.ReadFile(fullPath)
		if err != nil || isBinaryOrInvalidUTF8(data) {
			continue
		}

		strContent := string(data)
		if cfg.Tier == "arch" {
			if !isArchCandidate(f) {
				continue
			}
			if strings.HasSuffix(f, ".dhall") && len(data) > 50000 {
				continue
			}
			if strings.HasSuffix(f, ".hs") {
				strContent = extractArchSummaryHS(strContent)
			}
		}
		entries = append(entries, fileEntry{path: f, content: strContent})
	}

	blocks := entriesToBlocks(entries, cfg.MaxChars, cfg.AutoShard)
	return packBlocksIntoShards(cfg, repoName, prefix, commitSHA, commitTime, blocks), nil
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