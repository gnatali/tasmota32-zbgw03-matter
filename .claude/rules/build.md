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
  - in a Claude Code web session: `gh` only serves for search there, use the GitHub MCP tools
    (`actions_run_trigger` for the build, `pull_request_read` for PRs, `actions_list` /
    `get_job_logs` to follow the run);
  - locally: `gh api -X POST repos/gnatali/tasmota32-zbgw03-matter/actions/workflows/build.yml/dispatches -f ref=<branch>`
    (REST API: GraphQL is not available from Claude Code).
- The firmware is in the run's `firmware` artifact (`tasmota32-zbgw03-matter.bin` for an
  update, `.factory.bin` for a first flash).
- Before adding a patch: check that it applies to `TASMOTA_REF` **together with the existing
  patches** (`git apply --check`), and start the file with a comment header explaining why.
