// Additive in-process libFuzzer harness for fancy-regex.
//
// Preserves the upstream fuzz target NAME (fuzz_parser) for Mayhem target parity,
// but exercises more of the crate than upstream's parse-only harness: it parses
// the pattern (Expr::parse_tree), then — for patterns that compile — actually
// COMPILES the Regex and runs a match against a small fixed subject. This drives
// the parser, compiler, and VM/backtracking engine (the bug-prone code paths)
// without any disk I/O. Upstream source is untouched; this crate only CALLS it.
//
// The fuzz input is treated as a &str (the regex pattern). fancy-regex is a regex
// engine: a natural harness feeds fuzz bytes as a pattern to compile/match.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // 1. Parse path (what upstream's harness exercised).
    let _ = fancy_regex::Expr::parse_tree(data);

    // 2. Compile + match path (parser -> compiler -> VM / backtracking engine).
    //    Cap pattern length so pathological catastrophic-backtracking patterns
    //    don't dominate the whole time budget (this is a size cap, NOT a signal
    //    guard — signal guards break atheris-style coverage but this is Rust; the
    //    cap only keeps throughput up so coverage keeps growing). The real defects
    //    remain reachable within this bound.
    if data.len() > 512 {
        return;
    }
    if let Ok(re) = fancy_regex::Regex::new(data) {
        // Bound the backtracking work via a small, fixed subject. is_match returns
        // Result (it can error, e.g. backtrack-limit exceeded) — we only need to
        // drive the engine, so discard the result either way.
        let _ = re.is_match("aXbYcZ 123 foo foo\n");
    }
});
