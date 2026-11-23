#!/bin/sh
set -e

go vet ./scripts/tools/nadiverse-profile.go
go build -o /tmp/nadiverse-profile-test ./scripts/tools/nadiverse-profile.go
go test -v -run TestProfile ./scripts/tools/...
