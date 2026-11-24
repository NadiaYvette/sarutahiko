#!/bin/sh
set -e

go vet ./scripts/tools/nadiverse-rollup.go
go build -o /tmp/nadiverse-rollup-test ./scripts/tools/nadiverse-rollup.go
go test -v ./scripts/tools/...
/tmp/nadiverse-rollup-test -repo . -prefix packages/kogaki -tier arch -dry-run -out /tmp/kogaki-rollup-preview.md
