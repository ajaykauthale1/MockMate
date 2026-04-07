# Release Guide

How to build and ship MockMate for Windows.

---

## Prerequisites

| Tool | Install |
|------|---------|
| Flutter SDK `^3.11.0-200.1.beta` | [flutter.dev](https://flutter.dev/docs/get-started/install) |
| Rust stable 1.76+ | `rustup update stable` |
| Inno Setup 6+ | [jrsoftware.org/isinfo.php](https://jrsoftware.org/isinfo.php) |

---

## 1. Update the version

Edit two files before every release:

**`pubspec.yaml`**
```yaml
version: 1.2.0+3   # name+buildNumber
```

**`installer/windows/mockmate.iss`**
```
#define AppVersion "1.2.0"
```

---

## 2. Run tests

```sh
# Rust
cargo test --manifest-path rust/Cargo.toml

# Flutter
flutter test
```

Fix any failures before continuing.

---

## 3. Build the Flutter Windows release

```sh
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\`

---

## 4. Build the installer

```sh
iscc installer\windows\mockmate.iss
```

Output: `installer\windows\output\MockMateSetup-<version>.exe`

---

## 5. Smoke-test the installer

1. Run `MockMateSetup-<version>.exe` on a clean machine (or VM).
2. Complete the onboarding wizard end-to-end.
3. Run a general interview turn and a coding interview turn.
4. Uninstall via Add/Remove Programs — verify no leftover files in `%ProgramFiles%\MockMate`.

---

## 6. Tag and push

```sh
git tag v1.2.0
git push origin main --tags
```

---

## 7. Publish the release

1. Go to **GitHub → Releases → Draft a new release**.
2. Select the tag `v1.2.0`.
3. Upload `MockMateSetup-1.2.0.exe`.
4. Write release notes (what changed, known issues).
5. Publish.

---

## Troubleshooting

**`flutter build windows` fails with Rust link error**
Run `cargo build --release --manifest-path rust/Cargo.toml` first to see the raw Rust error.

**Inno Setup can't find `app_icon.ico`**
Make sure `windows/runner/resources/app_icon.ico` exists. Flutter creates it on first `flutter create`.

**`forceSameCodegenVersion: false` warning in logs**
Expected — the FRB generated files were manually extended for phase 8. Re-run `flutter_rust_bridge_codegen generate` from the repo root to regenerate cleanly, then remove the flag.
