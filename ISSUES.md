# Known Issues

## Medium Severity

- [ ] **Aggregate parsing boundary** — `parser.zig` ~line 951. `parse_aggregate()` captures from after the opening `{` to `pos - 1`, which may include the closing `}` in the returned slice depending on lexer positioning.

- [ ] **Fragile lexer state save/restore in lookahead** — `parser.zig` ~line 1015. `is_label_coming()` manually saves/restores 4 lexer fields. If the lexer gains new stateful fields in the future, this will silently break.

- [ ] **`@intCast` vs `@as` for usize→u64** — `encoding.zig` line 168, `message.zig` lines 191, 277. Several places use `@intCast(data.len)` to convert `usize` to `u64`. `@as(u64, data.len)` is more explicit and won't panic on hypothetical future platforms.

## Low Severity / Design

- [ ] **No capacity limits on repeated field decode** — Each element triggers a reallocation, so a malicious message with millions of tiny repeated fields could cause memory exhaustion.
