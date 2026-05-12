# Ralph Progress Log

This file tracks progress across iterations. Agents update this file
after each iteration and it's included in prompts for context.

## Codebase Patterns (Study These First)

- **Test target needs `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**: The main app target uses this setting, making all types MainActor-isolated. The test target must also set this to avoid `await` overhead on every cross-actor call.
- **`$(EXECUTABLE_PATH)` resolves per-target**: In TEST_HOST build setting, use a hardcoded path like `$(BUILT_PRODUCTS_DIR)/NemoNoise.app/Contents/MacOS/NemoNoise` — `$(EXECUTABLE_PATH)` resolves to the current target's executable, not the host app's.
- **`PBXFileSystemSynchronizedRootGroup`**: Modern Xcode (objectVersion 77) auto-discovers files in synchronized root groups. Add files to the directory and they appear in the target automatically.
- **`@Observable` classes have settable properties**: In tests, you can directly set `ModelManager.senseVoiceState` etc. to control state for testing.

---

## 2026-05-12 - US-008
- Added NemoNoiseTests unit test target with 34 tests across 5 test suites
- Files changed:
  - NemoNoiseTests/ASRServiceMockTests.swift (6 tests: mock conformance, isStreaming, feedChunk, finish, reset, multiple feeds)
  - NemoNoiseTests/SpeechOrchestratorTests.swift (6 tests: isStreaming default, finalize empty, stop safety, callback setup)
  - NemoNoiseTests/AudioCaptureTests.swift (4 tests: stop safety, multi-stop, AudioChunk creation)
  - NemoNoiseTests/TextInjectorTests.swift (3 tests: AX inject without target, capture with no focus)
  - NemoNoiseTests/ModelManagerTests.swift (15 tests: state mapping, modelPath nil/valid, state transitions, descriptor properties)
  - NemoNoise.xcodeproj/project.pbxproj (added NemoNoiseTests target with PBXContainerItemProxy, PBXTargetDependency)
  - NemoNoise.xcodeproj/xcshareddata/xcschemes/NemoNoise.xcscheme (shared scheme with test action)
- **Learnings:**
  - Modern Xcode project format (objectVersion 77) uses PBXFileSystemSynchronizedRootGroup for auto-discovery
  - Adding a test target requires: PBXFileReference, PBXContainerItemProxy, PBXTargetDependency, PBXFileSystemSynchronizedRootGroup, PBXNativeTarget, build phases, build configs, and config list
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on main target makes ALL types MainActor-isolated; test target must match this setting
  - ModelManager's @Observable properties are directly settable in tests for state machine verification

## 2026-05-12 - US-013
- Created GitHub Actions CI workflow and README with status badge
- Files changed:
  - .github/workflows/ci.yml (build + test job on macos-15, triggers on push/PR to main/develop)
  - README.md (new file with CI badge, features, build/test instructions)
- **Learnings:**
  - GitHub Actions macos-15 runners have Xcode 16.x pre-installed; select specific version with `xcode-select`
  - Disable code signing in CI with `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
  - xcpretty pipes xcodebuild output for cleaner CI logs; use `PIPESTATUS[0]` to preserve exit code

## 2026-05-12 - US-014
- Created DMG packaging and GitHub Releases v1.0 infrastructure
- Files changed:
  - build.sh (enhanced with version extraction, Sparkle appcast.xml generation, SHA-256 output)
  - .github/workflows/release.yml (new: release workflow triggered by version tags)
  - README.md (updated with full features, install instructions, OS requirements, build-from-source)
  - NemoNoise/Resources/Assets.xcassets/AppIcon.appiconset/ (placeholder blue icon with "N" letter, all sizes)
  - NemoNoise/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json (updated with filenames)
- **Learnings:**
  - Placeholder icons can be generated purely in Python with `struct`+`zlib` for raw PNG creation — no PIL needed
  - Sparkle appcast.xml needs `sparkle:edSignature` for secure updates; left empty for now since ad-hoc signing doesn't produce EdDSA keys
  - GitHub Actions release workflow uses `softprops/action-gh-release@v2` to create releases with DMG + appcast artifacts
  - `hdiutil create -srcfolder` handles DMG creation with Applications symlink automatically
  - Version extraction from Xcode project: `xcodebuild -showBuildSettings | grep MARKETING_VERSION`
---