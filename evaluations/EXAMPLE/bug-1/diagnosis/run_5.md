# diagnosis/run_5.md

> Single-turn diagnosis output, network locked, web tools off. No follow-ups.

## Answer

The root cause is in `src/main/java/mod1/ClassB2.java`: the caller re-invokes the
operation after it has already completed. `ClassB2.submit` does not check whether the
previous call already succeeded before re-submitting, so it issues a second request
(logged as `Event A9` twice), which produces the duplicate side effect (`Event A10`).

To fix, `ClassB2` should record the completion of the first submit and skip the second.