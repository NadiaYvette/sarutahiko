//go:build ignore

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runAutoHealOnFile(t *testing.T, initialContent, compilerLog string) string {
	t.Helper()
	dir := t.TempDir()
	filePath := filepath.Join(dir, "Test.hs")
	if err := os.WriteFile(filePath, []byte(initialContent), 0644); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	logReplaced := strings.ReplaceAll(compilerLog, "Test.hs", filePath)
	applied := autoHealLog(logReplaced, false)
	if applied == 0 {
		t.Fatalf("expected auto-heal edits to be applied, got 0")
	}

	resultBytes, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("failed to read result file: %v", err)
	}
	return string(resultBytes)
}

func TestGHC66111SingleLine(t *testing.T) {
	initial := `module Test where

import Control.Applicative
import Data.Text (Text)

foo :: Text
foo = undefined
`
	log := `Test.hs:3:1: warning: [GHC-66111] [-Wunused-imports]
    The import of ‘Control.Applicative’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	if strings.Contains(res, "Control.Applicative") {
		t.Fatalf("expected Control.Applicative to be removed, got:\n%s", res)
	}
	if !strings.Contains(res, "import Data.Text (Text)") {
		t.Fatalf("expected Data.Text to remain, got:\n%s", res)
	}
}

func TestGHC66111MultiLine(t *testing.T) {
	initial := `module Test where

import Data.List
  ( foldl'
  , intercalate
  )
import Data.Text (Text)

foo :: Text
foo = undefined
`
	log := `Test.hs:3:1: warning: [GHC-66111] [-Wunused-imports]
    The import of ‘Data.List’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	if strings.Contains(res, "Data.List") || strings.Contains(res, "foldl'") || strings.Contains(res, "intercalate") {
		t.Fatalf("expected entire multi-line Data.List import to be removed, got:\n%s", res)
	}
	if !strings.Contains(res, "import Data.Text (Text)") {
		t.Fatalf("expected Data.Text to remain, got:\n%s", res)
	}
}

func TestGHC38856FirstItem(t *testing.T) {
	initial := `module Test where

import Polytropos.Core (Pair(..), Rep(..), RowRep(..))

foo :: Int
foo = 42
`
	log := `Test.hs:3:25: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘Pair(..)’ from module ‘Polytropos.Core’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "import Polytropos.Core (Rep(..), RowRep(..))"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}

func TestGHC38856MiddleItem(t *testing.T) {
	initial := `module Test where

import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)

foo :: Int
foo = 42
`
	log := `Test.hs:3:48: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘readIORef’ from module ‘Data.IORef’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "import Data.IORef (atomicModifyIORef', newIORef, writeIORef)"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}

func TestGHC38856LastItem(t *testing.T) {
	initial := `module Test where

import GHC.TypeLits (Symbol, KnownSymbol)

foo :: Int
foo = 42
`
	log := `Test.hs:3:30: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘KnownSymbol’ from module ‘GHC.TypeLits’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "import GHC.TypeLits (Symbol)"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}

func TestGHC38856OnlyItem(t *testing.T) {
	initial := `module Test where

import Smirk.Core.Types (Fuel (..))
import Data.Text (Text)

foo :: Text
foo = undefined
`
	log := `Test.hs:3:26: warning: [GHC-38856] [-Wunused-imports]
    The import of ‘Fuel(..)’ from module ‘Smirk.Core.Types’ is redundant
`
	res := runAutoHealOnFile(t, initial, log)
	if strings.Contains(res, "Smirk.Core.Types") {
		t.Fatalf("expected whole import to be removed when only symbol is redundant, got:\n%s", res)
	}
	if !strings.Contains(res, "import Data.Text (Text)") {
		t.Fatalf("expected Data.Text to remain, got:\n%s", res)
	}
}

func TestGHC83475RecordWildcard(t *testing.T) {
	initial := `module Test where

buildChunkStalk :: Regex -> Int
buildChunkStalk Regex{..} = 0
`
	log := `Test.hs:4:23: warning: [GHC-83475] [-Wunused-record-wildcards]
    No variables bound in the record pattern are used
    Suggested fix: Remove ‘..’ or use a wild card pattern
`
	res := runAutoHealOnFile(t, initial, log)
	expected := "buildChunkStalk Regex{} = 0"
	if !strings.Contains(res, expected) {
		t.Fatalf("expected %q, got:\n%s", expected, res)
	}
}
