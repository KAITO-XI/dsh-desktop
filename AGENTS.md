# DSH Desktop repository rules

This repository owns the desktop product around an unmodified DeepSeek Harness checkout.

## Prerequisites and setup

- Use Node.js `^22.19.0` or `>=24.0.0` and the root Yarn `4.18.0` release through Corepack.
- Initialize the pinned upstream checkout with `git submodule update --init --recursive`.
- Install root dependencies with `corepack yarn install --immutable`.

## Build, run, and verify

- Start the desktop development workflow with `corepack yarn dev`.
- Build the desktop package with `corepack yarn build`.
- Before each release, run `corepack yarn aa:prepare-release` to build the latest official Agents Anywhere `main` for both Desktop channels. Commit the resulting artifact, provenance, manifests, and lockfile before packaging. Signed macOS releases and root Windows distribution commands verify freshness and installed versions; `DSH_AA_SOURCE_REF=pinned` is no longer supported.
- Run unit tests with `corepack yarn test`.
- Run type checking with `corepack yarn typecheck`.
- Run the complete headless gate with `corepack yarn check`.
- Develop and validate Desktop feature changes in `dsh-plugin-desktop-beta/` first, then synchronize shared changes into `dsh-plugin-desktop/` while preserving declared variant differences. Before committing or pushing shared Desktop changes, run `corepack yarn check:desktop-variants` and validate both affected packages; neither package automatically inherits the other's source edits.
- Run upstream operations through the root scripts, such as `corepack yarn upstream:build`.

- `deepseek-harness/` is a pinned upstream Git submodule. Never edit files inside it from a desktop feature branch.
- `dsh-plugin-desktop/` owns the Cordis Host and Client faces, Electron bootstrap, packaging, and release tests.
- `dsh-community-fabric/` owns the community interoperability RFC. Until schemas and a reviewed reference adapter exist, it remains a private documentation scaffold and must not declare loadable DSH or package entry points.
- `dsh-community-market/` owns the community-market shell. Until its runtime is implemented, it remains a private documentation scaffold and must not declare loadable DSH or package entry points.
- The outer repository and all owned packages use the root Yarn release with `nodeLinker: node-modules`.
- The upstream submodule keeps its own pnpm workspace. Run upstream commands through the root `upstream:*` scripts, whose Yarn portable-shell commands enter the submodule before invoking Corepack.
- Compatibility mode must run the upstream default client without overrides. Advanced presentation belongs to desktop-owned client plugins and may replace documented slots or services through profile composition.
- Keep graphical application launch explicit. Builds, typechecks, unit tests, and Loader smokes must remain headless-safe.
- Commit before major changes of direction and keep the submodule pin update separate from desktop behavior changes.
- Keep the repository topology and package-manager split consistent with the [owning Agent Note](.agents/notes/implemented/process/2026-08-15-pinned-upstream-and-isolated-yarn-workspace.md).

## Local patch branches

- This checkout carries local-only commits on top of an upstream release tag. Read `local-patches.json` (baseline tag, patch list, verify rules) and `docs/local-branch-strategy.md` before creating or moving any branch. The baseline follows the *installed* DSH Desktop release tag, never `main`.
- Agents must auto-detect drift on arrival: compare `baseline` in `local-patches.json` against the version at `installedAppProbe`. On mismatch, propose `scripts/sync-local-patches.ps1 -Check` first, then run it without `-Check` to fetch the tag, cherry-pick the patch stack, rebuild, verify, and refresh the manifest.
- Local patch branches are pushed to the `fork` remote (public fork `KAITO-XI/dsh-desktop`; its public visibility is intentional and accepted) and optionally to `backup` (private mirror `KAITO-XI/dsh-desktop-local`). Never push `origin` (upstream `anywhere-labs/dsh-desktop`, formerly `deepseek-harness-desktop`) or `mirror`. Always use the canonical upstream name: the old name only survives as a redirect and confuses fork/ls-remote checks.
- Any new local customization must land as its own commit series, update `local-patches.json` (`patches` + `verify`), and, when it changes the workflow, `docs/local-branch-strategy.md`.
- Customizations that also need machine-local state (files outside the repo, autostart entries, user settings) must declare an idempotent script under `local-patches.json` > `machineSetup`; `scripts/sync-local-patches.ps1` runs those on every sync so a fresh machine converges. Current example: the OpenCode Go search proxy (`docs/web-search-opencode-go.md`).
- Running the locally built desktop app has its own runbook: `docs/launch-from-source.md`. Two traps it documents: `enableScripts: false` means Electron's binary must be fetched by hand, and the installed app holds the shared single-instance lock, so quit it first (or isolate with `--user-data-dir`).
- Generated build artifacts that dirty the tree (for example `dsh-plugin-desktop/build/app-icon.ico`) should be restored with `git restore` before committing.
