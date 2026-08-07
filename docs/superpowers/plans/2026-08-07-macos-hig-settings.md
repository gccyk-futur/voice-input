# macOS HIG Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild VoiceKit’s settings and readability foundation around macOS conventions without changing ASR, paste, history, or channel behavior.

**Architecture:** Keep `SettingsView` as the feature entry point, but replace its top segmented navigation with a stable sidebar/detail shell. Add small, testable value types for text scale, semantic display state, and channel-aware write-back copy. Propagate text scale through a shared environment value and use system semantic colors rather than hard-coded visual colors.

**Tech Stack:** Swift 6, SwiftUI, AppKit, macOS 14, XCTest, XcodeGen.

## Global Constraints

- Preserve the existing ASR, audio, pre-roll, paste, history, engine selection, and signing behavior.
- Default to macOS system fonts and semantic colors; do not add a custom font dependency.
- Support three text-size presets: system, large, extraLarge; avoid an arbitrary slider in this phase.
- Keep meaningful explanatory text at Body/Callout scale; reserve Caption for metadata.
- App Store copy must describe clipboard + keyboard-event write-back as an attempt with manual ⌘V fallback.
- Direct-distribution Accessibility copy must distinguish direct insertion from clipboard fallback.
- New behavior must be test-first: add a failing focused test before production implementation.

---

### Task 1: Add pure UI state models and focused tests

**Files:**
- Create: `Sources/VoiceKit/Settings/VoiceKitUIState.swift`
- Create: `Tests/VoiceKitTests/VoiceKitUIStateTests.swift`
- Modify: `project.yml`

**Interfaces:**
- `enum VoiceKitTextScale: String, CaseIterable, Sendable` with `.system`, `.large`, `.extraLarge` and a stable `multiplier`.
- `enum VoiceKitDistribution: Sendable` with `.direct` and `.appStore`.
- `struct WriteBackPresentation: Equatable, Sendable` containing title, explanation, and fallback explanation for a distribution and permission state.

- [x] Write tests for stable text-scale multipliers and display titles.
- [x] Run the focused tests and confirm they fail because the models do not exist.
- [x] Write tests for direct/App Store write-back copy across not-determined, denied, and granted states.
- [x] Implement the minimal enums and copy factory with no SwiftUI dependency.
- [x] Run `VoiceKitUIStateTests` and confirm green.

### Task 2: Build the settings navigation shell

**Files:**
- Modify: `Sources/VoiceKit/Settings/SettingsView.swift`
- Modify: `Sources/VoiceKit/Settings/SettingsWindowController.swift`
- Create: `Sources/VoiceKit/Settings/SettingsNavigation.swift` only if the shell needs extraction.

- [x] Write a view-model/state test for restoring the last selected settings pane without depending on AppKit.
- [x] Replace the top segmented picker with a sidebar/detail layout using native SwiftUI navigation primitives.
- [x] Give each pane a title and description; keep the selected pane visible and keyboard navigable.
- [x] Let the window resize naturally instead of forcing every pane to the same 500pt height.
- [x] Set a comfortable minimum width and preserve the last selected pane while the settings window remains open.
- [x] Keep Save/Cancel behavior unchanged; text scale and pane selection are safe immediate UI preferences.
- [x] Build the app target and inspect compile output before changing content styling.

### Task 3: Add typography scale and semantic colors

**Files:**
- Create: `Sources/VoiceKit/Settings/VoiceKitTypography.swift`
- Create: `Sources/VoiceKit/Settings/VoiceKitSemanticColors.swift`
- Modify: `Sources/VoiceKit/Settings/SettingsView.swift`
- Modify: `Sources/VoiceKit/Panel/PanelView.swift`
- Modify: `Sources/VoiceKit/App/StatusBarMenu.swift`
- Modify: `Sources/VoiceKit/History/HistoryView.swift`
- Modify: `Sources/VoiceKit/Config/ConfigStore.swift` or the existing config model only where the text-scale preference is persisted.

- [x] Write tests for default/system, large, and extra-large scale persistence and reset behavior.
- [x] Add the preference under General → Appearance with a three-option picker.
- [x] Inject the selected scale into custom text while leaving native controls system-managed.
- [x] Replace important `.caption2`/`.tertiary` uses with the typography and semantic-color roles.
- [x] Use system colors and preserve dark mode, Increase Contrast, and status color + icon/text redundancy.
- [ ] Verify long copy wraps without clipping at all three scales (manual acceptance remains).
- [x] Run the full unit suite after the typography pass.

### Task 4: Rebuild permissions and channel-aware write-back guidance

**Files:**
- Modify: `Sources/VoiceKit/Settings/SettingsView.swift`
- Modify: `Sources/VoiceKit/Paste/PasteService.swift` only if restart/reload state needs a narrow API.
- Modify: `Sources/VoiceKit/Coordinator/AppCoordinator.swift` only if the existing status state needs to expose a user-facing write-back outcome.
- Modify: `Tests/VoiceKitTests/VoiceKitUIStateTests.swift`

- [x] Write tests for permission state labels, channel-specific copy, and restart recommendation state.
- [x] Remove the global static restart paragraph and make restart messaging permission-specific.
- [x] On direct distribution, explain Accessibility direct insertion versus clipboard fallback.
- [x] On App Store distribution, show keyboard-event write-back and explain attempted automation plus manual ⌘V fallback.
- [x] Add a visible `现在重启 VoiceKit` action only when the relevant permission has just become usable and reload is recommended.
- [x] Add a non-destructive “稍后处理” path; never terminate the app without an explicit user action.
- [x] Refresh the permission presentation when returning from System Settings without changing the core permission request flow.
- [x] Run focused UI-state tests and the full unit suite.

### Task 5: Visual and release verification

**Files:**
- No source changes expected unless verification exposes a defect.

- [x] Run `git diff --check` and inspect the complete diff for scope creep.
- [x] Build Debug and Release app targets for Swift 6/macOS 14.
- [x] Run the complete unit-test suite and record the result.
- [ ] Inspect the settings window in light mode, dark mode, Increase Contrast, and all text-size presets (manual acceptance remains).
- [x] Verify keyboard navigation affordances in native controls, add VoiceOver labels for icon-only actions, and keep permission copy wrapping.
- [x] Build and verify both direct-distribution and App Store condition archives without changing entitlements.
- [x] Hand off the archives for final manual acceptance; do not claim HIG compliance from compilation alone.

## Completion Review

- [x] Settings navigation, typography, colors, permission copy, and restart action meet the written design.
- [x] Existing ASR, paste, history, and channel behavior remain unchanged in source scope.
- [ ] Automated tests, builds, archive checks, and visual/manual checks have evidence (visual acceptance remains).
