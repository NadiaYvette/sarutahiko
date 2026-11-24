// nadiverse-rollup: Roll git repositories into structured Markdown digests and
// update linked Google Docs in place for Gemini Notebook auto-sync.
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

func main() {
	cfg := RollupConfig{}
	flag.StringVar(&cfg.RepoDir, "repo", ".", "Path to git repository")
	flag.StringVar(&cfg.Prefix, "prefix", "", "Optional tracked path prefix (e.g. packages/kogaki)")
	flag.StringVar(&cfg.Key, "key", "", "Lookup key in -map-file (default: repo or repo:prefix)")
	flag.StringVar(&cfg.DocTitle, "title", "", "Google Doc title when creating a new doc")
	flag.StringVar(&cfg.Tier, "tier", "arch", "Digest tier: 'arch' (interfaces+docs) or 'full'")
	flag.IntVar(&cfg.MaxChars, "max-chars", 950000, "Max Unicode character count (Google Docs cap ~1.02M)")
	flag.StringVar(&cfg.OutFile, "out", "", "Optional local path to write Markdown digest")
	flag.StringVar(&cfg.MapFile, "map-file", defaultMapPath(), "JSON file mapping rollup keys to Drive Doc IDs")
	flag.BoolVar(&cfg.DryRun, "dry-run", false, "Build digest locally without calling Google Drive API")
	flag.BoolVar(&cfg.CreateMissing, "create-missing", false, "Create a new Google Doc if key is absent from -map-file")
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

	md, stats, err := buildMarkdownRollup(cfg, repoName, cleanPrefix)
	if err != nil {
		return err
	}
	fmt.Printf("[nadiverse-rollup] key=%s tier=%s commit=%s files=%d runes=%d words=%d bytes=%d\n",
		cfg.Key, cfg.Tier, stats.CommitSHA, stats.Files, stats.Runes, stats.Words, stats.Bytes)

	if cfg.MaxChars > 0 && stats.Runes > cfg.MaxChars {
		return fmt.Errorf("digest has %d characters, exceeding -max-chars=%d (split with -prefix or use -tier=arch)",
			stats.Runes, cfg.MaxChars)
	}

	if cfg.OutFile != "" {
		if err := os.MkdirAll(filepath.Dir(cfg.OutFile), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(cfg.OutFile, []byte(md), 0o644); err != nil {
			return err
		}
		fmt.Printf("[nadiverse-rollup] wrote %s\n", cfg.OutFile)
	}

	if cfg.DryRun {
		return nil
	}

	client := &http.Client{Timeout: 60 * time.Second}
	token, err := resolveAccessToken(client, cfg.TokenURL)
	if err != nil {
		return err
	}

	docID, created, err := upsertGoogleDoc(client, cfg, token, md)
	if err != nil {
		return err
	}
	action := "updated in place"
	if created {
		action = "created (attach once to Gemini Notebook)"
	}
	fmt.Printf("[nadiverse-rollup] %s: https://docs.google.com/document/d/%s/edit\n", action, docID)
	return nil
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

func loadRollupIgnore(repoDir string) []string {
	ignorePath := filepath.Join(repoDir, ".rollupignore")
	data, err := os.ReadFile(ignorePath)
	if err != nil {
		return nil
	}
	var patterns []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		patterns = append(patterns, line)
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
	case ".patch", ".hi", ".o", ".tix", ".mix":
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
	if base == "README.md" || base == "PLAN.md" || base == "STATE.md" {
		return true
	}
	if strings.HasPrefix(clean, "docs/notes/") && strings.HasSuffix(base, ".md") {
		return true
	}
	if strings.HasSuffix(base, ".dhall") {
		return true
	}
	if strings.HasSuffix(base, ".hs") {
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

		// Block comments / Haddock
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

		// Module header: from 'module ...' up to 'where'
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

		// Docstrings
		if strings.HasPrefix(trimmed, "-- |") || strings.HasPrefix(trimmed, "-- ^") || strings.HasPrefix(trimmed, "-- *") {
			result = append(result, line)
			continue
		}

		// Check if top-level declaration starting at column 0
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

func buildMarkdownRollup(cfg RollupConfig, repoName, prefix string) (string, RollupStats, error) {
	shaOut, err := gitCmd(cfg.RepoDir, "rev-parse", "--short=12", "HEAD")
	if err != nil {
		return "", RollupStats{}, fmt.Errorf("git rev-parse HEAD: %w", err)
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
		return "", RollupStats{}, fmt.Errorf("git ls-files: %w", err)
	}

	rawFiles := strings.Split(strings.TrimSpace(lsOut), "\n")
	var trackedFiles []string
	for _, f := range rawFiles {
		f = strings.TrimSpace(f)
		if f != "" {
			trackedFiles = append(trackedFiles, f)
		}
	}
	sort.Strings(trackedFiles)

	ignorePatterns := loadRollupIgnore(cfg.RepoDir)

	var selectedFiles []string
	type fileEntry struct {
		path    string
		content string
	}
	var entries []fileEntry

	for _, f := range trackedFiles {
		if shouldExclude(f, ignorePatterns) {
			continue
		}

		fullPath := filepath.Join(cfg.RepoDir, f)
		data, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}

		if isBinaryOrInvalidUTF8(data) {
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

		selectedFiles = append(selectedFiles, f)
		entries = append(entries, fileEntry{path: f, content: strContent})
	}

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("# Monorepo Digest: %s\n\n", cfg.Key))
	sb.WriteString(fmt.Sprintf("- **Repository:** `%s`\n", repoName))
	if prefix != "" {
		sb.WriteString(fmt.Sprintf("- **Prefix:** `%s`\n", prefix))
	}
	sb.WriteString(fmt.Sprintf("- **Commit:** `%s` (%s)\n", commitSHA, commitTime))
	sb.WriteString(fmt.Sprintf("- **Tier:** `%s`\n", cfg.Tier))
	sb.WriteString(fmt.Sprintf("- **Tracked Files:** %d\n\n", len(selectedFiles)))

	sb.WriteString("## Tracked File Tree\n\n```\n")
	for _, f := range selectedFiles {
		sb.WriteString(f + "\n")
	}
	sb.WriteString("```\n\n")

	for _, entry := range entries {
		ext := filepath.Ext(entry.path)
		lang := strings.TrimPrefix(ext, ".")
		if lang == "hs" {
			lang = "haskell"
		} else if lang == "md" {
			lang = "markdown"
		}
		sb.WriteString(fmt.Sprintf("## File: %s\n\n```%s\n%s\n```\n\n", entry.path, lang, strings.TrimRight(entry.content, "\n")))
	}

	md := sb.String()
	stats := RollupStats{
		CommitSHA: commitSHA,
		Files:     len(selectedFiles),
		Bytes:     len(md),
		Runes:     utf8.RuneCountInString(md),
		Words:     len(strings.Fields(md)),
	}

	return md, stats, nil
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

func upsertGoogleDoc(client *http.Client, cfg RollupConfig, token string, md string) (string, bool, error) {
	mapData := make(map[string]string)
	if data, err := os.ReadFile(cfg.MapFile); err == nil {
		_ = json.Unmarshal(data, &mapData)
	}

	docID := mapData[cfg.Key]
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
		return "", false, fmt.Errorf("no doc_id mapped for key %q in %s; pass -create-missing to create one", cfg.Key, cfg.MapFile)
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
		"name":     cfg.DocTitle,
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

	mapData[cfg.Key] = cr.ID
	if err := os.MkdirAll(filepath.Dir(cfg.MapFile), 0o755); err == nil {
		if outBytes, err := json.MarshalIndent(mapData, "", "  "); err == nil {
			_ = os.WriteFile(cfg.MapFile, outBytes, 0o644)
		}
	}

	return cr.ID, true, nil
}
