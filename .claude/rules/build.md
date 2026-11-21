---
paths:
  - "platformio_override.ini"
  - "user_config_override.h"
  - "patches/**"
  - ".github/**"
---
# Firmware build

- Only on GitHub Actions, **not locally** (heavy toolchain). Triggers: `v*` tag (also creates
  the release) and manual run. **A PR triggers nothing**: run the build on a branch
  (`build.yml` workflow, `ref=<branch>`):
  - with `gh api` (REST only, GraphQL is refused, so no `gh run` / `gh pr`), also in a Claude Code
    web session since the GitHub MCP tools were retired (November 2026):
    `gh api -X POST repos/gnatali/tasmota32-zbgw03-matter/actions/workflows/build.yml/dispatches -f ref=<branch>`
    ; follow it with `.../actions/runs/<id>` and `.../actions/jobs/<job>/logs`.
- The firmware is in the run's `firmware` artifact (`tasmota32-zbgw03-matter.bin` for an
  update, `.factory.bin` for a first flash): give Guillaume its download link (`project.md`,
  "Reporting a build").
- Before adding a patch: check that it applies to `TASMOTA_REF` **together with the existing
  patches** (`git apply --check`), and start the file with a comment header explaining why.
