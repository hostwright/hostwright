# Verification

- Keep tests focused on shipped, supported behavior. Prefer existing coverage.
- Add or expand a test only for a demonstrated bug or a necessary behavior boundary. Keep the regression as small as possible.
- Do not add tests that merely mirror implementation, duplicate existing assertions, or exercise deferred features. Reversible documentation and formatting changes do not need new tests.
- Run the smallest relevant checks once. Repeat them only after relevant changes or failures; let PR CI run its existing gate.
- Run expensive release, sanitizer, fuzz, and physical-host qualification at the required candidate gates, not after every edit.
- Remove obsolete or redundant tests with a concrete reason and identify retained coverage where applicable. A failure alone does not make a test obsolete.
- Report the checks actually run and any remaining gaps. Do not claim all unnecessary tests have been removed without reviewing the remaining suite.
