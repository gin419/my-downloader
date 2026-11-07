---
id: TASK-3
title: >-
  Run full XCTest suite once Xcode is installed (verify likes redownload-missing
  + auto-sync tests)
status: To Do
assignee: []
created_date: '2026-11-07T23:02:00Z'
labels:
  - testing
dependencies: []
type: task
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The tests for the Likes redownload-missing feature (TASK-1) and the Likes auto-sync feature (TASK-2) were never run under real XCTest, because this Mac only had Command Line Tools (no full Xcode).

Once Xcode is installed, run the full XCTest suite and confirm the tests for both features pass.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Full XCTest suite runs under Xcode
- [ ] #2 Likes redownload-missing tests pass
- [ ] #3 Likes auto-sync tests pass
<!-- AC:END -->
