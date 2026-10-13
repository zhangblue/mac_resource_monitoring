# Intel Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one macOS 13+ universal DMG for arm64 and Intel x86_64 with independently honest temperature and fan readings.

**Architecture:** Compile-time `#if arch(x86_64)`/`#elseif arch(arm64)` in `ProviderSet.live` selects a lazily opened architecture-specific SMC sensor within each universal slice. Keep the engine's outer sensor failure boundary while splitting temperature and fan into separate `Reading` values; build thin SwiftPM binaries, merge before signing, and verify both slices in both app copies.

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest, AppleSMC read-only IOKit, bash, `lipo`, `vtool`, `codesign`, `hdiutil`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-13-intel-support-design.md`

## Global Constraints

- macOS 13.0+, arm64 plus x86_64 in a **single** app and DMG; keep `LSUIElement=true`.
- No new dependency/permission, SMC writes, disk I/O-rate metric, real login-item changes, or change to ad-hoc/unnotarized distribution.
- Preserve menu-bar CPU/memory/upload/download, 1/3/5-second refresh, 1/5/10-minute history (default 1 second/5 minutes, 600-point cap), capacity-only startup disk, sleep reset.
- Intel CPU-temperature candidates `TC0P`/`TC0D` are **unverified hypotheses**: do not claim verified support; verify on actual Intel hardware before releasing claims.
- This document authorizes planning only; product/test/build/CI edits below are future execution tasks, not actions in MRM-INTEL-03. Do not push/tag/publish or alter real login items without separate authorization.

## Review Focus

- `FNum` absent or invalid: fan unavailable, not fanless (Task 2 test).
- Some Intel candidate keys fail or contain plausible non-CPU temperatures: skip failure, never broaden to ambient/battery key (Task 2 test).
- Valid temperature plus failed fan (and inverse): retain the successful independent reading (Tasks 1–3 tests).
- Cross-compile succeeds while x86_64 runtime/SMC fails: mark hardware acceptance blocked, not passed (Task 5 gate).
- Stale arm64 app or stale DMG survives partial build: scripts fail closed, never report old artifact as universal (Task 4 negative verification).

---

## File map / task order

1. Domain/engine/UI failure semantics: `MetricSnapshot.swift`, `MonitoringEngine.swift`, `MenuBarPresentation.swift`, `DashboardView.swift` and existing tests.
2. Sensor policies and dispatch: `AppleSiliconSensorProvider.swift`, new `IntelSensorProvider.swift`, shared `SMCSensorReadings.swift`, `ProviderProtocols.swift`, sensor tests.
3. Engine and UI integration regression: existing engine/UI tests, diagnostics; separate reviewer gate for user-visible behavior.
4. Universal package: `build-app.sh`, `verify-release.sh`, script test harness, optionally `build-dmg.sh` only if stale-artifact guard needs it.
5. Release gate and docs: `.github/workflows/release.yml`, `README.md`, `INSTALL.md`, `AGENTS.md`, `docs/verification/2026-10-01-release-checklist.md`; Intel hardware sign-off separately blocked.

Each task has its own red/green or artifact validation and review gate; proceed in order. Commits in the future implementation work are suggestions, **not instructions to commit this documentation stage**.

### Task 1: Split thermal value semantics without changing other metric flows

**Files:**
- Modify: `Sources/MacResourceMonitor/Domain/MetricSnapshot.swift:30-39`
- Modify: `Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift:228-295`
- Modify: `Sources/MacResourceMonitor/UI/MenuBarPresentation.swift:96-116`
- Modify: `Sources/MacResourceMonitor/UI/DashboardView.swift:47-50,116-135`
- Test: `Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`, `Tests/MacResourceMonitorTests/UITests.swift`, `Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift`, `Tests/MacResourceMonitorTests/SMCDecoderTests.swift` (fixture migration)

**Interfaces:**
- Consumes: existing `Reading<Value>`, `SensorProviding.sample() async throws -> ThermalMetric`, `MetricSnapshot.thermal: Reading<ThermalMetric>`.
- Produces: `ThermalMetric.temperature: Reading<Double>` and `ThermalMetric.fan: Reading<FanMetric>`; preserve `.rpm(Double)` and `.fanless` cases. `MetricPresentation.temperatureStatus(for: Reading<ThermalMetric>?) -> String` plus `fanStatus(for: Reading<ThermalMetric>?) -> String` (or pure `ThermalPresentation` with two static methods; choose the named methods to avoid interface drift).

- [ ] **Step 1: Write failing tests.** `testIndependentThermalPresentation`: `.value(ThermalMetric(temperature: .value(54.5), fan: .unavailable("missing")))` presents `54 °C` (existing rounded visual convention), fan `— / 暂不可用`; inverse presents `— / 暂不可用` for temperature and valid fan `1820 RPM`; nil snapshot shows waiting; outer unavailable shows both unavailable. Put values/status formatting in `MetricPresentation.temperatureText(for:)`, `fanText(for:)`, `temperatureStatus(for:)`, `fanStatus(for:)` so these are testable without a SwiftUI snapshot. `testSensorSubfailureDiagnostic` uses fake provider and logger to assert sensor failure logged even when outer thermal is `.value`, CPU/memory/network/disk still committed, and next successful sensor clears failure.
- [ ] **Step 2: Run `swift test --filter 'UITests|MonitoringEngineTests'`; expect compilation/test failure on new accessors or assertions.**
- [ ] **Step 3: Implement model and pure presentation functions, migrate fixture constructors, and make dashboard use each reading.** Keep `MonitoringEngine.collect`'s outer catch; in `recordDiagnostics`, special-case `.sensors` and inspect both sub-readings, recording a stable combined failure reason (no raw secret data), and success only if both succeed. Use `Reading.value` accessors to avoid mapping failures through `MetricFormatter`'s zero clamp.
- [ ] **Step 4: Run `swift test --filter 'UITests|MonitoringEngineTests|SamplingBoundaryTests|SMCDecoderTests'`; expect pass.** Task 2 supplies actual independently sampled values; until then adapt the existing Apple Silicon provider minimally to return two fields and preserve existing fan-failure behavior internally (no fake value).
- [ ] **Step 5: Review diff for unchanged menu-bar fields, history/sleep logic, and disk capacity model; commit this independently reviewable slice when implementing.**

### Task 2: Independent architecture-specific read-only SMC policies

**Files:**
- Create: `Sources/MacResourceMonitor/Providers/IntelSensorProvider.swift`
- Create: `Sources/MacResourceMonitor/Providers/SMC/SMCSensorReadings.swift`
- Modify: `Sources/MacResourceMonitor/Providers/AppleSiliconSensorProvider.swift`
- Modify: `Sources/MacResourceMonitor/Monitoring/ProviderProtocols.swift:19-49`
- Test: `Tests/MacResourceMonitorTests/SMCDecoderTests.swift`, create `Tests/MacResourceMonitorTests/IntelSensorProviderTests.swift`, create `Tests/MacResourceMonitorTests/ProviderSelectionTests.swift`

**Interfaces:**
- Consumes: Task 1 `ThermalMetric(temperature: Reading<Double>, fan: Reading<FanMetric>)`, existing `SMCTransport.read(_:)`, `.allKeys()`, `SMCValue.decoded()`.
- Produces: `IntelSensorProvider.init(transport: any SMCTransport)`, `init() throws`, `sample() -> ThermalMetric`; shared `SMCSensorReadings.fan(from: any SMCTransport) throws -> FanMetric`; `AppleSiliconSensorProvider` same constructor/sample surface; private lazy actor in `ProviderProtocols.swift` stores `any SensorProviding` and picks concrete provider in `#if arch(x86_64)` / `#elseif arch(arm64)` / `#else #error(...)` once, then samples it. If existential synchronous `sample()` actor isolation needs explicit `try await`, follow protocol's async requirement and keep lazy initialization error outside the two subreads.

- [ ] **Step 1: Write failing fake-transport tests.** `testIntelTemperatureWithoutFan` uses candidate `TC0P` with synthetic `sp78` 54.5 and failing `FNum`: temperature `.value(54.5)`, fan `.unavailable`. `testIntelFanWithoutTemperature` uses no valid CPU candidate, `FNum=1`, `F0Ac` `fpe2` 1820: temperature unavailable, fan `.rpm(1820)`. `testVerifiedZeroCountVersusMissing` distinguishes `FNum=0` => `.fanless`, absent/invalid count => unavailable; `FNum=1` and `F0Ac=0` => `.rpm(0)`. `testCandidatesFailClosed` rejects non-finite/out-of-range, unknown types and only non-CPU `TB0T` data; failure of first candidate may use second candidate. `testAppleSiliconFanFailureRetainsTemperature` uses `Tp01` valid + `FNum` failure. Test a transport that fails enumeration, malformed count, partial multi-fan read, and independent recovery at next sample. Architecture conditional test checks `ProviderSet.live`'s selected provider via a package-internal architecture marker/factory injection that does **not** open live SMC; assert x86_64 selects Intel, arm64 Apple Silicon; compile both slices.
- [ ] **Step 2: Run `swift test --filter 'IntelSensorProviderTests|SMCDecoderTests|ProviderSelectionTests'`; expect compilation/test failure.**
- [ ] **Step 3: Implement shared fan validation with 0...10 integer count, nonnegative finite RPM, all expected fans readable; independently catch fan/temperature errors in both concrete providers.** Intel direct candidate reads only (`TC0P`, `TC0D`, pending hardware confirmation), finite 10...125 °C; do not use `allKeys()` broad `T*` fallback or assume `flt ` Intel byte order. For CPU candidates stop at first credible value; preserve Apple Silicon `Tp` selection. Leave `SMCClient` read-only with unchanged ABI, no write commands.
- [ ] **Step 4: Run `swift test --filter 'IntelSensorProviderTests|SMCDecoderTests|ProviderSelectionTests'` and `swift test`; expect pass.** Review every `.fanless` construction: only credible `FNum=0`.
- [ ] **Step 5: Commit sensor policies separately after review.**

### Task 3: End-to-end regression of failure isolation and existing UX

**Files:**
- Test: `Tests/MacResourceMonitorTests/MonitoringEngineTests.swift`, `Tests/MacResourceMonitorTests/UITests.swift`, `Tests/MacResourceMonitorTests/SamplingBoundaryTests.swift`, `Tests/MacResourceMonitorTests/MonitoringSettingsTests.swift`
- Modify: `Sources/MacResourceMonitor/Monitoring/MonitoringEngine.swift` / `UI/DashboardView.swift` only if regression reveals a specific bug.

**Interfaces:**
- Consumes: Tasks 1–2 `ThermalMetric` independent readings and `ProviderSet` injection; no new product interface.
- Produces: cross-provider and UI regression gate.

- [ ] **Step 1: Add missing failure-and-recovery tests.** Inject failed temperature/successful fan and inverse into engine, assert both remain visible independently, other four providers remain available, `.sensors` diagnostics failure then recovery; test menu bar still only four metrics, disk capacity-only, settings persistence/windows, sleep wake first CPU/network sample baseline unavailable then next sample rate, and history gap retention. Reuse existing tests when they assert exact behavior; don't duplicate whole suites.
- [ ] **Step 2: Run `swift test --filter 'MonitoringEngineTests|UITests|SamplingBoundaryTests|MonitoringSettingsTests'`; expect new behavior tests to fail before corrective implementation (if already green, record that the gate is covered rather than force artificial failure).**
- [ ] **Step 3: Apply only fixes indicated by red tests; leave `LoginItemManager` and real login-item state untouched.**
- [ ] **Step 4: Run `swift test` and `swift build -c release --arch arm64`; expect zero failures/exit 0.** Never treat earlier 136-test baseline as final evidence.
- [ ] **Step 5: Commit regression gate separately, if new tests or fixes were needed.**

### Task 4: Universal executable and DMG verification

**Files:**
- Modify: `scripts/build-app.sh`, `scripts/verify-release.sh`
- Modify: `scripts/build-dmg.sh` only to prevent accepting a stale app if not already gated by caller/verifier.
- Create: `Tests/scripts/verify-universal-release.sh` (temporary fixture/script harness; do not put it in SwiftPM test target)

**Interfaces:**
- Consumes: SwiftPM CLI release `--arch arm64` / `--arch x86_64`, `--show-bin-path`; `dist/MacResourceMonitor.app`, `dist/MacResourceMonitor.dmg`.
- Produces: single signed `dist/MacResourceMonitor.app/Contents/MacOS/MacResourceMonitor` with both slices; `verify-release.sh` exits nonzero for wrong slice, target, signature, metadata, DMG contents.

- [ ] **Step 1: Add script harness negative tests:** a deliberately thin app binary, a wrong per-slice deployment target fixture where feasible, and a stale/inconsistent DMG must fail verification; the harness must use a scratch directory and override paths through explicit test-only args/env or extracted pure checker, never mutate real `dist/`. If Mach-O fixture creation is impractical, run verify on copied actual build then `lipo -thin` and re-sign the copy; record what could not be automated.
- [ ] **Step 2: Run `bash Tests/scripts/verify-universal-release.sh`; expect failure against current arm64-only checks (in particular x86_64-missing fixture must be rejected by the new assertion).**
- [ ] **Step 3: Build arm64 and x86_64 thin executables independently, check architecture and exit status, `lipo -create` into app, copy plist/icon, sign the completed bundle.** Remove target app before build; fail on absent/thin/mismatched output and never package a prior app. In `verify-release.sh`, use `lipo -archs` set equality for both installed and mounted copies, `vtool -show-build -arch arm64|x86_64` to assert each min OS 13.0, `shasum -a 256` equality, current metadata/signature/DMG checks and reliable detach trap; fail before release publishing.
- [ ] **Step 4: Run `bash Tests/scripts/verify-universal-release.sh`; expect all negative fixtures rejected and valid fixture accepted.** Then run in order `swift build -c release --arch arm64`, `swift build -c release --arch x86_64`, `bash scripts/build-app.sh`, `bash scripts/build-dmg.sh`, `bash scripts/verify-release.sh`; expect exit 0, `lipo -archs dist/MacResourceMonitor.app/Contents/MacOS/MacResourceMonitor` reports both architectures. This is a future execution gate, **not performed by this planning task**.
- [ ] **Step 5: Commit scripts plus harness only after verifying no `build/` or `dist/` files are staged.**

### Task 5: Release/documentation gate and hardware handoff

**Files:**
- Modify: `.github/workflows/release.yml`, `README.md`, `INSTALL.md`, `AGENTS.md`, `docs/verification/2026-10-01-release-checklist.md`
- Test: `.github/workflows/release.yml` static parsing / path assertions in a lightweight local script or CI validation.

**Interfaces:**
- Consumes: Task 4 app/DMG verification command, existing release DMG and SHA-256 paths.
- Produces: tag workflow that cannot create/upload release before universal checks; installation/support copy that never claims Intel sensor keys tested without evidence; hardware acceptance record (separate blocker).

- [ ] **Step 1: Add a failing workflow assertion that release creation follows `swift test`, both arch builds, app build, DMG build and `verify-release.sh` in one job, with checksum generated only after verify; ensure no release step can run on a failed check.** Check `macos-15` runner actually offers required SDK/architectures during execution, not by assumption.
- [ ] **Step 2: Run the static workflow check; expect failure on current arm64-only release chain.**
- [ ] **Step 3: Update workflow to explicitly cross-build both arch release binaries before scripts (or rely on Task 4's script and assert both builds through its log; avoid duplicate costly builds where possible). Update README, INSTALL, AGENTS, release checklist together with macOS 13+ two-arch support, one DMG, sensor best-effort failure text, arm64 regression and Intel hardware block. Keep ad-hoc/未公证 and first-open instructions aligned; do not claim hardware results or touch login item behavior.**
- [ ] **Step 4: Run static workflow check, `swift test`, `swift build -c release --arch arm64`, `swift build -c release --arch x86_64`, then `bash scripts/build-app.sh && bash scripts/build-dmg.sh && bash scripts/verify-release.sh`, `git diff --check`, `git status --short`; expect zero exit codes, dual-slice checks in app/DMG, only intended files changed.** No tag push, Release creation, install to `/Applications`, or real login-item toggle.
- [ ] **Step 5: On macOS 13+ Intel hardware (BLOCKED until device available), run `swift test`, launch the packaged x86_64 slice, verify CPU/memory/network/menu/settings/trends/disk/sleep, collect non-sensitive SMC key/type observations, and check temperature and fan independently. Record exact machine/OS, each test result and unavailable fallback; confirm `FNum=0` against actual fanless hardware if such device is available. Repeat arm64 launch/functional regression on Apple Silicon. Do not claim this step passed from cross-compilation or Rosetta.**
- [ ] **Step 6: Review documentation against actual observations, request product approval for any Intel sensor-coverage claim, and commit CI/docs changes only when accurate. Release/tag/push require separate authorization.**

## Final self-review and handoff

Spec mapping: independent sensor semantics Tasks 1–3; compile-time dispatch and Intel policy Task 2; universal app/DMG Task 4; workflow/docs Task 5; preserved UI/settings/capacity/sleep Task 3; hardware blocker Task 5. Names/types match Task 1 `ThermalMetric` and Task 2 provider interfaces. The current MRM-INTEL-03 deliverable is these two documents only. Recommend subagent-driven execution with review at each boundary because SMC fallback and release checks can independently fail without a visible compile error; coordinator decides after reviewing the plan. No hardware adaptation is represented as proven.
