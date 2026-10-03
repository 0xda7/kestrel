# Quarantine 2026-10-02 — files written by pi from inside a chat turn
Operator tested "self-improve the code base" in the Kestrel UI with the pi
(llm-space) engine. Pi's default bash/write tools were ACTIVE and it wrote
four Swift files into Sources/Chat/. They contain invalid Swift (TS-style
semantics: no actor initializers, broken ternaries, immutable-self assigns)
and broke `swift build`. Moved here verbatim by the harness; NOT compiled.
Restore only after human review. See mission plan AMENDMENT 4 (tool policy).
