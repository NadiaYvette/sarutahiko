package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExtractArchSummaryHS(t *testing.T) {
	input := `{-# LANGUAGE OverloadedStrings #-}
-- | Module: Test.Foo
-- Description: Test module for arch summary
module Test.Foo
  ( Bar(..)
  , runFoo
  ) where

import qualified Data.Text as T

-- | A test data type
data Bar
  = BarA !Int
  | BarB !T.Text
  deriving (Eq, Show)

-- | A test class
class Monad m => MonadFoo m where
  fooAction :: Int -> m Bar

-- | Top-level function signature
runFoo :: Int -> Bar
runFoo 0 = BarA 0
runFoo n =
  let x = n * 2
  in BarB (T.pack (show x))
`
	summary := extractArchSummaryHS(input)

	// Invariants:
	// 1. Module header, Bar data type, MonadFoo class, and runFoo type signature retained
	if !strings.Contains(summary, "module Test.Foo") {
		t.Errorf("expected module header in summary, got:\n%s", summary)
	}
	if !strings.Contains(summary, "data Bar") || !strings.Contains(summary, "BarA !Int") {
		t.Errorf("expected data Bar definition in summary, got:\n%s", summary)
	}
	if !strings.Contains(summary, "class Monad m => MonadFoo m where") {
		t.Errorf("expected class MonadFoo definition in summary, got:\n%s", summary)
	}
	if !strings.Contains(summary, "runFoo :: Int -> Bar") {
		t.Errorf("expected runFoo signature in summary, got:\n%s", summary)
	}
	// 2. Implementation details stripped
	if strings.Contains(summary, "let x = n * 2") {
		t.Errorf("expected function body to be stripped, got:\n%s", summary)
	}
}

func TestExclusionRules(t *testing.T) {
	patterns := []string{"*.gen.dhall", "secret/*"}

	cases := []struct {
		path     string
		excluded bool
	}{
		{"dist-newstyle/build/foo.o", true},
		{"packages/kogaki/dist-newstyle/cache", true},
		{"ref/pages/page_001.txt", true},
		{"build.log", true},
		{"diff.patch", true},
		{"Foo.hi", true},
		{"Foo.o", true},
		{"Foo.tix", true},
		{"test.gen.dhall", true},
		{"secret/creds.json", true},
		{"src/Main.hs", false},
		{"cabal.project", false},
		{"docs/notes/ARCHITECTURE.md", false},
	}

	for _, c := range cases {
		got := shouldExclude(c.path, patterns)
		if got != c.excluded {
			t.Errorf("shouldExclude(%q) = %v, expected %v", c.path, got, c.excluded)
		}
	}
}

func TestResolveAccessToken(t *testing.T) {
	// 1. Direct env token
	t.Setenv("NADIVERSE_GDRIVE_TOKEN", "direct-token-abc")
	client := &http.Client{}
	tok, err := resolveAccessToken(client, "http://invalid-url")
	if err != nil {
		t.Fatalf("unexpected error resolving direct token: %v", err)
	}
	if tok != "direct-token-abc" {
		t.Errorf("expected direct-token-abc, got %q", tok)
	}

	// 2. Token exchange via mock token server
	t.Setenv("NADIVERSE_GDRIVE_TOKEN", "")
	t.Setenv("NADIVERSE_GDRIVE_CLIENT_ID", "mock-client-id")
	t.Setenv("NADIVERSE_GDRIVE_CLIENT_SECRET", "mock-client-secret")
	t.Setenv("NADIVERSE_GDRIVE_REFRESH_TOKEN", "mock-refresh-token")

	tokenServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if err := r.ParseForm(); err != nil {
			t.Errorf("failed to parse form: %v", err)
		}
		if r.FormValue("client_id") != "mock-client-id" ||
			r.FormValue("client_secret") != "mock-client-secret" ||
			r.FormValue("refresh_token") != "mock-refresh-token" ||
			r.FormValue("grant_type") != "refresh_token" {
			t.Errorf("unexpected form values: %+v", r.Form)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"access_token": "exchanged-token-xyz",
		})
	}))
	defer tokenServer.Close()

	tok2, err := resolveAccessToken(client, tokenServer.URL)
	if err != nil {
		t.Fatalf("unexpected error in token exchange: %v", err)
	}
	if tok2 != "exchanged-token-xyz" {
		t.Errorf("expected exchanged-token-xyz, got %q", tok2)
	}
}

func TestUpsertGoogleDoc(t *testing.T) {
	tmpDir := t.TempDir()
	mapFilePath := filepath.Join(tmpDir, "rollup-map.json")

	// Prepopulate map file with an existing doc ID
	initialMap := map[string]string{
		"sarutahiko:packages/kogaki": "existing-doc-12345",
	}
	initBytes, _ := json.Marshal(initialMap)
	if err := os.WriteFile(mapFilePath, initBytes, 0o644); err != nil {
		t.Fatalf("failed to write map file: %v", err)
	}

	patchCalled := false
	createCalled := false

	mockDrive := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth != "Bearer test-bearer-token" {
			t.Errorf("expected Bearer token, got %q", auth)
		}

		if r.Method == "PATCH" && strings.Contains(r.URL.Path, "existing-doc-12345") {
			patchCalled = true
			if r.Header.Get("Content-Type") != "text/markdown; charset=utf-8" {
				t.Errorf("expected text/markdown; charset=utf-8, got %q", r.Header.Get("Content-Type"))
			}
			body, _ := io.ReadAll(r.Body)
			if !strings.Contains(string(body), "# Digest Content") {
				t.Errorf("unexpected PATCH body: %s", string(body))
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"id": "existing-doc-12345"}`))
			return
		}

		if r.Method == "POST" && strings.Contains(r.URL.RawQuery, "uploadType=multipart") {
			createCalled = true
			if !strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/related;") {
				t.Errorf("expected multipart/related content-type, got %q", r.Header.Get("Content-Type"))
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"id": "newly-created-doc-67890"}`))
			return
		}

		t.Errorf("unexpected request: %s %s?%s", r.Method, r.URL.Path, r.URL.RawQuery)
	}))
	defer mockDrive.Close()

	client := &http.Client{}

	// 1. In-place PATCH for existing doc
	cfgExisting := RollupConfig{
		Key:           "sarutahiko:packages/kogaki",
		MapFile:       mapFilePath,
		UploadBaseURL: mockDrive.URL,
	}
	docID, created, err := upsertGoogleDoc(client, cfgExisting, "test-bearer-token", "# Digest Content")
	if err != nil {
		t.Fatalf("unexpected error on existing doc PATCH: %v", err)
	}
	if !patchCalled {
		t.Errorf("expected PATCH to be called")
	}
	if created {
		t.Errorf("expected created=false for in-place PATCH, got true")
	}
	if docID != "existing-doc-12345" {
		t.Errorf("expected docID existing-doc-12345, got %s", docID)
	}

	// 2. Create missing doc via multipart POST
	cfgMissing := RollupConfig{
		Key:           "sarutahiko:packages/newpkg",
		DocTitle:      "Rollup: newpkg",
		MapFile:       mapFilePath,
		CreateMissing: true,
		UploadBaseURL: mockDrive.URL,
	}
	newDocID, created2, err := upsertGoogleDoc(client, cfgMissing, "test-bearer-token", "# New Package Digest")
	if err != nil {
		t.Fatalf("unexpected error on create missing POST: %v", err)
	}
	if !createCalled {
		t.Errorf("expected POST create to be called")
	}
	if !created2 {
		t.Errorf("expected created=true for new doc, got false")
	}
	if newDocID != "newly-created-doc-67890" {
		t.Errorf("expected newly-created-doc-67890, got %s", newDocID)
	}

	// Verify map file was updated on disk
	updatedBytes, err := os.ReadFile(mapFilePath)
	if err != nil {
		t.Fatalf("failed to read updated map file: %v", err)
	}
	var updatedMap map[string]string
	_ = json.Unmarshal(updatedBytes, &updatedMap)
	if updatedMap["sarutahiko:packages/newpkg"] != "newly-created-doc-67890" {
		t.Errorf("map file was not updated with new doc ID: %+v", updatedMap)
	}
}
