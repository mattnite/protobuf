# Building conformance_test_runner: Why It's Hard

The `conformance_test_runner` is a C++ binary from
[protocolbuffers/protobuf](https://github.com/protocolbuffers/protobuf).
Currently it's built externally with cmake and passed in via
`-Dconformance-runner=<path>`. This document explains why building it
with the Zig build system is non-trivial, in case you want to revisit.

## The Build Graph

The runner links four compiled components:

1. **conformance_test_runner sources** — 8 `.cc` files
2. **libprotobuf** — 79 `.cc` files (core C++ runtime)
3. **libconformance_common** — 7 generated `.pb.cc` files (requires protoc)
4. **abseil-cpp** — ~141 `.cc` files (Google's C++ standard library extensions)
5. **jsoncpp** — 3 `.cpp` files (JSON parsing, used by the runner for JSON test cases)
6. **utf8_range** — 1 `.c` file (vendored in protobuf's `third_party/`)

**Total: ~239 C/C++ source files**, plus protoc as a build-time tool.

## Specific Difficulties

### 1. Abseil is the biggest headache (~141 source files)

Abseil (`abseil-cpp`) is not vendored in the protobuf tree — cmake fetches
it from GitHub at configure time. It would need to be added as a Zig
dependency (lazy fetch or vendored).

The 141 files span 14 subdirectories: `base`, `container`, `crc`,
`debugging`, `flags`, `hash`, `log`, `numeric`, `profiling`, `random`,
`status`, `strings`, `synchronization`, `time`. Key complications:

- **Platform-specific sources compiled unconditionally**: All 5 waiter
  implementations (`futex_waiter.cc`, `pthread_waiter.cc`, `sem_waiter.cc`,
  `stdcpp_waiter.cc`, `win32_waiter.cc`) are compiled on every platform;
  runtime `#ifdef` selects the right one. Same for `crc_x86_arm_combined.cc`.

- **Architecture-sensitive files**: `randen_hwaes.cc` may need `-maes
  -msse4.1` on x86_64 (Bazel builds use these flags; cmake builds may not
  depending on configuration). The Zig build would need per-file compile
  flags.

- **Exclusion list is fragile**: You can't just glob `absl/**/*.cc` — you
  must exclude `*_test.cc`, `*_benchmark.cc`, plus ~10 specific files that
  are built as separate targets not needed by the runner (`poison.cc`,
  `scoped_set_env.cc`, `failure_signal_handler.cc`, `periodic_sampler.cc`,
  flags parse/usage files, etc.).

- **74 separate cmake targets**: Abseil's cmake produces 74 static `.a`
  archives with specific inter-target dependencies. A Zig build would need
  to flatten these into a single compilation unit or replicate the
  dependency graph.

### 2. Generated .pb.cc files require protoc

The runner needs 7 `.pb.cc` files generated from `.proto` sources:

```
conformance/conformance.pb.cc
conformance/test_protos/test_messages_edition2023.pb.cc
conformance/test_protos/test_messages_edition_unstable.pb.cc
editions/golden/test_messages_proto2_editions.pb.cc
editions/golden/test_messages_proto3_editions.pb.cc
src/google/protobuf/test_messages_proto2.pb.cc
src/google/protobuf/test_messages_proto3.pb.cc
```

This creates a chicken-and-egg problem: you need `protoc` to generate
these files, but `protoc` itself is another C++ binary that depends on
libprotobuf + abseil. Options are:

- Build protoc from source first (adds another ~50+ source files)
- Require protoc on PATH (breaks hermetic builds)
- Vendor the pre-generated `.pb.cc` files (version-coupled, brittle)

### 3. libprotobuf is large (79 source files)

The protobuf C++ runtime includes JSON parsing, text format, reflection,
descriptors, arenas, wire format, and all well-known type `.pb.cc` files.
The include path setup is non-trivial (`src/` for main headers, build
output dir for generated headers, `third_party/utf8_range/` for utf8).

### 4. jsoncpp is an external dependency

Version 1.9.6, fetched by cmake from GitHub. Only 3 source files, but
it's yet another dependency to vendor or fetch.

### 5. Include path complexity

The cmake build uses these include paths:
```
-I<protobuf_root>/src                  # main protobuf headers
-I<build_dir>                          # generated .pb.h files
-I<build_dir>/_deps/absl-src           # abseil headers
-I<protobuf_root>/third_party/utf8_range
-I<jsoncpp_root>/include
```

Plus the conformance-specific headers in `<protobuf_root>/conformance/`.

### 6. Version coupling

The abseil version must match what protobuf expects. As of protobuf
v35.0.0, the pinned version is `abseil-cpp 20250512.1`. jsoncpp is
pinned at `1.9.6`. Updating protobuf may require updating these in
lockstep.

## What a Zig Build Would Look Like

If you wanted to do this, you'd need:

1. Add `abseil-cpp` and `jsoncpp` as lazy dependencies in `build.zig.zon`
2. Add the protobuf C++ source as a dependency (or reference it by path)
3. Create a `build.zig` step that:
   - Compiles 141 abseil `.cc` files with correct include paths
   - Compiles 79 libprotobuf `.cc` files
   - Either runs protoc to generate 7 `.pb.cc` files, or vendors them
   - Compiles 3 jsoncpp `.cpp` files
   - Compiles 1 utf8_range `.c` file
   - Compiles 8 runner `.cc` files
   - Links everything together
4. Handle per-file compile flags for architecture-sensitive abseil files

## Current Approach: CI-Only

The runner is built in CI using cmake:
```bash
git clone --depth=1 https://github.com/protocolbuffers/protobuf /tmp/protobuf
cd /tmp/protobuf && mkdir build && cd build
cmake .. -Dprotobuf_BUILD_CONFORMANCE=ON
cmake --build . --target conformance_test_runner
```

Then passed to Zig:
```bash
cd conformance
zig build -Dconformance-runner=/tmp/protobuf/build/conformance_test_runner run
```

The `protobuf-conformance` npm package also provides prebuilt binaries for
`linux-x64` and `darwin-x64` (but not `linux-arm64`).
