# symptom.md — bug-1

A long-running operation that should complete exactly once is being executed more than
once. After a successful completion, the caller logs that it is "re-trying" the operation,
and the operation runs again, producing duplicate side effects (the downstream system
records the result twice). The log shows the success of the first attempt followed
immediately by a retry marker and a second attempt, despite no error having occurred.

This is the failure to diagnose. Do not assume anything about the system or any known fix.