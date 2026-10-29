# Java parity claims (gh-430)

dmtools-dart is a port of the Java dmtools (https://github.com/epam/dm.ai).
Any finding or change justified by "the Java version does X" MUST be verified,
not recalled from memory.

1. Verify against a fresh shallow clone of the Java repo, never a cached or
   remembered copy:
   `git clone --depth 1 --filter=blob:none https://github.com/epam/dm.ai /tmp/dm.ai`
2. Cite every Java behaviour claim as `path/File.java:NN` (repo-relative path
   and line number) so the reader can check it, e.g.
   `dmtools-core/src/main/java/com/github/istin/dmtools/.../Foo.java:123`.
3. Reviewers: a parity finding WITHOUT such a citation is NOT blocking — post
   it as a non-blocking question ("does Java do X? please cite"), never as a
   change request.
4. Rework: when a reviewer cites Java code, re-read the cited lines in a fresh
   clone before changing behaviour; if the citation does not support the
   claim, reply with the correct citation instead of changing code.
