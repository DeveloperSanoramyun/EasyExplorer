#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/FileExplorerCoreTests.XXXXXX")
trap 'rm -rf "$TASK_TMP"' EXIT
python3 Tests/make_fixtures.py "$TASK_TMP/fixtures"
xcrun swiftc -import-objc-header FileExplorer/ArchiveBridge.h -D CORE_TESTS -module-cache-path "$TASK_TMP/modules" -larchive \
  FileExplorer/Services/SafeFileOperations.swift \
  FileExplorer/Services/FileOperationService.swift \
  FileExplorer/Services/ArchiveService.swift \
  FileExplorer/Services/FolderSizeService.swift \
  FileExplorer/Services/SpotlightSearchService.swift \
  Tests/CoreTests.swift -o "$TASK_TMP/tests"
"$TASK_TMP/tests" "$TASK_TMP/fixtures"
