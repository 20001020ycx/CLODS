#!/usr/bin/env python3
"""Build private/anonymization_map.json for HDFS-14135 and apply it to a source tree.

  anon_map_build.py write <path/to/anonymization_map.json>
  anon_map_build.py apply <map.json> <file> [<file> ...]

The map is the single source of truth for M4: `apply` rewrites whole-word occurrences,
longest key first, so nested names (testConnectTimeout inside testRedirectConnectTimeout)
can never be half-substituted.
"""
import json
import re
import sys

# (a) bug-id scrub: the JIRA id never appears in Hadoop source; verified by verify_anon.sh.
# (b)+(c) failure-path file/type, helper and case-naming identifier renames.
IDENTIFIERS = {
    # file + public type on the failure path (root cause and symptom site)
    "TestWebHdfsTimeouts": "TestWebHdfsClientDeadlines",
    # the helper the ticket discussion names, and its constants
    "consumeConnectionBacklog": "fillPendingConnectQueue",
    "startSingleTemporaryRedirectResponseThread": "startOneShotRedirectResponder",
    "CLIENTS_TO_CONSUME_BACKLOG": "PENDING_CONNECT_CLIENTS",
    "CONNECTION_BACKLOG": "LISTEN_QUEUE_LENGTH",
    # the case's test-method names, as they appear in CI reports and in stack frames
    "testConnectTimeout": "testListFilesConnectDeadline",
    "testReadTimeout": "testListFilesReadDeadline",
    "testAuthUrlConnectTimeout": "testDelegationTokenConnectDeadline",
    "testAuthUrlReadTimeout": "testDelegationTokenReadDeadline",
    "testRedirectConnectTimeout": "testChecksumRedirectConnectDeadline",
    "testRedirectReadTimeout": "testChecksumRedirectReadDeadline",
    "testTwoStepWriteConnectTimeout": "testCreateRedirectConnectDeadline",
    "testTwoStepWriteReadTimeout": "testCreateRedirectReadDeadline",
}

# (d) failure-path log/fail literals, rewritten to neutral, information-equivalent text.
LITERALS = {
    "expected timeout": "expected a socket deadline",
    "unexpected IOException in server thread": "responder thread aborted on I/O error",
    "open URL connection": "establishing HTTP connection",
    "Not enabling OAuth2 in WebHDFS": "OAuth2 support is disabled for WebHDFS",
    "open file: ": "opening file: ",
}

FAILURE_PATH = {
    "renamed": {
        "hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web/TestWebHdfsTimeouts.java":
            "hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web/TestWebHdfsClientDeadlines.java",
    },
    "kept_generic": [
        "hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/web/WebHdfsFileSystem.java",
        "hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/web/URLConnectionFactory.java",
        "hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web/WebHdfsTestUtil.java",
        "hadoop-common/src/test/java/org/apache/hadoop/test/GenericTestUtils.java",
    ],
    "chain": [
        "TestWebHdfsTimeouts.consumeConnectionBacklog() — root cause: returns as soon as the "
        "non-blocking connect() calls have been issued",
        "TestWebHdfsTimeouts.test*ConnectTimeout() — drives the WebHDFS operation that is "
        "expected to hit a connect deadline",
        "WebHdfsFileSystem$AbstractRunner.run/connect/runWithRetry — issues the HTTP request",
        "URLConnectionFactory.openConnection — creates the HttpURLConnection and applies the "
        "connect/read deadlines",
        "GenericTestUtils.assertExceptionContains — where the wrong deadline surfaces as the "
        "observable failure",
    ],
}


def build():
    return {
        "bug": "the JIRA id and its bare number appear nowhere in source/ or the logs",
        "identifiers": IDENTIFIERS,
        "log_literals": LITERALS,
        "failure_path": FAILURE_PATH,
    }


def apply_map(mapping, paths):
    table = dict(mapping["identifiers"])
    table.update(mapping["log_literals"])
    keys = sorted(table, key=len, reverse=True)
    pat = re.compile("|".join(re.escape(k) for k in keys))
    for p in paths:
        with open(p, encoding="utf-8") as f:
            s = f.read()
        out = pat.sub(lambda m: table[m.group(0)], s)
        if out != s:
            with open(p, "w", encoding="utf-8") as f:
                f.write(out)
            print(f"[anon] rewrote {p}")


def main():
    if sys.argv[1] == "write":
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            json.dump(build(), f, indent=2)
            f.write("\n")
        print(f"[anon] wrote {sys.argv[2]}")
    elif sys.argv[1] == "apply":
        mapping = json.load(open(sys.argv[2], encoding="utf-8"))
        apply_map(mapping, sys.argv[3:])
    else:
        sys.exit("usage: anon_map_build.py write|apply ...")


if __name__ == "__main__":
    main()
