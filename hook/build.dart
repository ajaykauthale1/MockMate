// Native assets build hook — compiles the Rust mockmate-bridge crate and
// registers the output shared library with Flutter's native asset system.
//
// Flutter invokes this automatically during `flutter build` and `flutter run`
// once native assets are enabled:
//   flutter config --enable-native-assets

import 'dart:io';

import 'package:native_assets_cli/code_assets.dart';
import 'package:native_assets_cli/native_assets_cli.dart';

const _crateName = 'mockmate-bridge';
const _libStem = 'mockmate_bridge'; // without prefix / suffix

Future<void> main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;
    final rustTarget = _rustTriple(os, arch);

    // ── 1. Compile Rust library ───────────────────────────────────────────────
    final rustRoot = input.packageRoot.resolve('rust/');
    final cargoArgs = [
      'build',
      '--release',
      '-p',
      _crateName,
      if (rustTarget != null) ...['--target', rustTarget],
    ];

    final result = await Process.run(
      'cargo',
      cargoArgs,
      workingDirectory: rustRoot.toFilePath(),
    );

    if (result.exitCode != 0) {
      throw ProcessException(
        'cargo',
        cargoArgs,
        'cargo build failed:\n${result.stderr}',
        result.exitCode,
      );
    }

    // ── 2. Resolve output library path ────────────────────────────────────────
    final releaseSubdir = rustTarget != null
        ? 'mockmate-bridge/target/$rustTarget/release/'
        : 'mockmate-bridge/target/release/';

    final libUri = rustRoot.resolve('$releaseSubdir${_libFileName(os)}');

    // ── 3. Register with Flutter native assets ────────────────────────────────
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _libStem,
        file: libUri,
        linkMode: DynamicLoadingBundled(),
      ),
    );

    // Invalidate when key Rust sources or manifest change.
    output.addDependencies([
      rustRoot.resolve('mockmate-bridge/src/bridge.rs'),
      rustRoot.resolve('mockmate-bridge/Cargo.toml'),
      rustRoot.resolve('Cargo.toml'),
    ]);
  });
}

/// Map Flutter's (OS, Architecture) to a Rust target triple.
/// Returns null for the host triple (no `--target` flag needed).
String? _rustTriple(OS os, Architecture arch) => switch ((os, arch)) {
      (OS.windows, Architecture.x64) => null,   // host on Windows x64
      (OS.linux, Architecture.x64) => null,      // host on Linux x64
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      _ => null,
    };

/// Platform-specific shared library file name (with prefix/suffix).
String _libFileName(OS os) => switch (os) {
      OS.windows => '$_libStem.dll',
      OS.macOS => 'lib$_libStem.dylib',
      OS.linux => 'lib$_libStem.so',
      _ => throw UnsupportedError('Unsupported OS for packaging: $os'),
    };
