# Ground truth — bug-1 (PRIVATE, never shown to the diagnosis LLM)

Derived from `private/fix.diff`.

## Root-causing line(s)
- File: `ClassA1.java` (anonymized from `RetryHandler.java`)
- Line 88 (in the anonymized tree): the `shouldRetry` guard inside `handle(...)`.

## Exact wrong branch / condition
Before the fix, the retry decision was:

```java
if (response != Response.OK) {       // WRONG: retries on every non-OK, including the
    retry();                          //        successful-but-non-OK intermediate state,
}                                    //        and ALSO never distinguishes retryable errors.
```

The bug: the guard checked `response != Response.OK`. On the failure path, the first
attempt completes successfully but the response object carries an intermediate non-OK
status (`PARTIAL_ACK`) that is *not* an error. The guard misclassifies it as "needs retry"
and re-runs the operation, producing duplicate side effects.

The fix changed the condition to check the *positive* retryable-error signal:

```java
if (response == Response.RETRYABLE_ERROR) {
    retry();
}
```

## What a correct diagnosis must name
1. The branch at `ClassA1.java` L88 (the `if` that decides whether to retry).
2. The exact wrong condition: `response != Response.OK` (or equivalently, that the retry
   decision is based on "not OK" rather than "is a retryable error"), causing a successful
   non-OK intermediate state to spuriously trigger a retry.