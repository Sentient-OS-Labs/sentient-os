# macOS CI

The `macos.yml` workflow builds the full Debug app on an Apple Silicon `macos-26` runner
with Xcode 26.6. Code signing is disabled for the build, so no signing certificates or
release credentials are required. The workflow does not publish releases.

It runs for pull requests targeting `main`, pushes to `main`, `fix/**` and `feat/**`,
and manual dispatch. New pushes cancel an older run for the same ref.

When `Scripts/test_knowledge_search.py` is present, the workflow runs its regression
checks before building. This step is skipped on branches without the harness, allowing
the build workflow to work independently of the search feature.

Build logs, available test logs and the Xcode result bundle are uploaded even when a
step fails and retained for seven days. Each job has a 30-minute timeout. Fork PRs may
need maintainer approval before the upstream run can start.

These checks cover compilation and the available search regression harness. Interactive
UI and system-permission acceptance still require a real app session.
