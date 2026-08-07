# Aliyun Audio Preroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Aliyun startup tolerant of users speaking immediately after the hotkey by buffering a bounded amount of local PCM until the remote task is ready, without changing local engines or the verified permission, paste, and history paths.

**Architecture:** Add a pure, thread-safe `AudioPreRollBuffer` for one Aliyun task. Start capture while the task is in `starting`, route audio into the buffer, then atomically drain the buffer through the existing serial WebSocket send queue after the matching `task-started` event. Only after the drain is enqueued does `AlibabaASREngine.start()` return, allowing the coordinator to show `聆听中…` and play the start cue. Cancellation and failures discard the buffer and invalidate late callbacks.

**Tech Stack:** Swift 6, macOS 14, AVFAudio, URLSession WebSocket, XCTest, XcodeGen project configuration.

## Global Constraints

- Scope the pre-roll path to `AlibabaASREngine`; do not add a remote queue to `SystemDictationEngine` or `LegacyDictationEngine`.
- Preserve the existing `ASREngine` public contract, permission flow, paste/rewrite behavior, engine selection, and task lifecycle protections.
- Keep the buffer bounded at approximately one second of 16 kHz mono 16-bit PCM (about 32 KB); overflow must be explicit and must not silently discard recognized speech.
- Keep send ordering on one serial boundary; do not rely on concurrent Task scheduling.
- Every new session owns its buffer and task identity; late events from old sessions must not send audio.
- Do not log recognized text, API keys, or AI-collaboration metadata.
- Follow test-driven development: add a failing focused test before each behavior implementation, then run the focused test and the full suite.
- Before claiming completion, run `git diff --check`, the full unit-test command, and the App Store archive build/signature verification used by this project.

---

## Task 1: Add the pure bounded pre-roll buffer

**Files:**
- Create `Sources/VoiceKit/ASR/AudioPreRollBuffer.swift`.
- Create `Tests/VoiceKitTests/AudioPreRollBufferTests.swift`.
- Update `project.yml` to include the new source in `VoiceKitTests`.

- [x] Define the buffer state and result types with explicit transitions: buffering, draining/live handoff, and discarded.
- [x] Add a capacity in bytes with a default matching approximately one second of 16 kHz mono 16-bit PCM.
- [x] Add append behavior that preserves FIFO order and returns an overflow result instead of silently truncating.
- [x] Add a one-shot drain operation returning buffered chunks in order and preventing a second drain.
- [x] Ensure append/drain/discard are safe when called from audio and WebSocket callback contexts.
- [x] Write tests first for FIFO ordering and byte accounting.
- [x] Write tests first for overflow, one-shot drain, post-drain live handoff, and discard behavior.
- [x] Run only `AudioPreRollBufferTests` and confirm all focused tests pass.

## Task 2: Add Aliyun send-gate integration

**Files:**
- Modify `Sources/VoiceKit/ASR/AlibabaASREngine.swift`.
- Modify `Tests/VoiceKitTests/AudioPreRollBufferTests.swift` or add a focused engine-send-gate test file if the test seam requires it.

- [x] Introduce a per-task send gate that owns the buffer phase and routes data through the existing `sendQueue` and `AudioSendDrain`.
- [x] Make audio callbacks buffer before `task-started`; verify no WebSocket audio send is initiated during buffering.
- [x] On the matching `task-started`, enqueue the buffered chunks first, then switch the gate to live sending for subsequent chunks.
- [x] Ensure the gate is idempotent for duplicate/old `task-started` events and rejects data after discard.
- [x] Preserve the existing audio conversion format and send payload shape.
- [x] Add a focused test proving `buffered-1`, `buffered-2`, `live-1` ordering and no duplicate drain.
- [x] Run the focused buffer/send-gate tests before changing the broader lifecycle.

## Task 3: Reorder Alibaba startup without weakening cancellation

**Files:**
- Modify `Sources/VoiceKit/ASR/AlibabaASREngine.swift`.
- Add or extend focused lifecycle tests under `Tests/VoiceKitTests` as needed.

- [x] Install callbacks and start `AudioCapture` after input preflight but before waiting for `task-started`, with the send gate still buffering.
- [x] Keep `run-task` registration and task ID checks intact; only the audio capture point changes.
- [x] On successful matching `task-started`, drain the buffer and let `start()` return only after the initial sends are committed to the serial send path.
- [x] On `AudioCapture.start` failure, task-start timeout, task-start rejection, or cancellation, stop capture and discard the gate before returning the error.
- [x] Preserve the existing `starting` → `finishing` behavior when stop is requested before `task-started`.
- [x] Prevent a late `task-started` from starting a cancelled or invalidated session.
- [x] Preserve `AudioSendDrain` close/wait semantics so `finish-task` cannot overtake accepted audio.
- [x] Add logs for gate creation, buffered byte count, drain start/completion, overflow, and discard reason using task ID only.
- [x] Add focused gate/lifecycle coverage for audio-before-task-start, cancellation/discard during preparation, and late task-start data.
- [x] Run the focused lifecycle tests and the full unit suite.

## Task 4: Align coordinator readiness and recovery behavior

**Files:**
- Inspect and modify `Sources/VoiceKit/Coordinator/AppCoordinator.swift` only if the engine return boundary requires it.
- Modify `Sources/VoiceKit/Coordinator/RecordingRecovery.swift` only if an explicit pre-roll overflow/retry notice is needed.
- Extend `Tests/VoiceKitTests/RecordingRecoveryTests.swift` or add coordinator-focused tests if behavior changes.

- [x] Confirm local engines retain their current start behavior and do not instantiate the Aliyun buffer.
- [x] Confirm the coordinator remains in `preparing` until `engine.start()` returns, then changes to `recording` and plays the start sound once.
- [x] If overflow is surfaced, map it to a clear retryable notice without exposing internal PCM/task terminology.
- [x] Verify the existing “no microphone / input device / permission / service unavailable” notices remain unchanged unless a test proves a necessary addition.
- [x] Add or update tests for the readiness boundary and overflow recovery copy.
- [x] Run the full unit suite again.

## Task 5: Build, package, and regression verify

**Files:**
- No source changes expected unless verification exposes a defect.
- Use the existing project scripts and archive output under `/private/tmp`.

- [x] Run `git diff --check` and inspect the complete diff for scope creep.
- [x] Run `xcodebuild -project VoiceKit.xcodeproj -scheme VoiceKitTests -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/voicekit-tests-preroll test`.
- [x] Build the App Store archive using the project’s existing App Store build flow.
- [x] Verify the archive app is universal, signed with the Apple Distribution certificate, and passes the project’s strict codesign checks.
- [x] Inspect the resulting log format to ensure new logs contain no recognized text or collaboration metadata.
- [x] Hand off the archive for the three-device test matrix: immediate speech after F2, repeated starts, cancel during preparation, no microphone, Bluetooth input switch, Aliyun/local switching, history, and paste-back.
- [ ] Record any device-only result separately; do not claim the timing fix is complete based solely on unit tests or a successful archive build.

## Completion Review

- [x] Confirm only Aliyun gained pre-roll behavior.
- [x] Confirm first audio is FIFO-preserved, bounded, and never silently discarded.
- [x] Confirm cancellation/failure cannot leak audio into the next session.
- [x] Confirm the coordinator’s “聆听中…” and start cue correspond to the engine-ready boundary.
- [x] Confirm all tests and package verification pass before creating the implementation commit.
