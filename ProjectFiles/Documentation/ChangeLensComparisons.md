# Bounded change-lens comparisons

`AgentTaskChangeLensDiff.build()` keeps the existing normalized line model,
1,000-line limit, cancellation result, removal-first LCS ties, three-line
context, and original line offsets used by scope warnings and passage corrections.
It changes only the portion of the comparison matrix that needs computing.

Equal normalized text returns no hunks before allocating a matrix, after the
existing line-limit and cancellation checks. A shared leading region can always
be excluded: the existing traceback consumes equal leading lines immediately.
A shared trailing region is excluded only when none of its line values occurs
in either remaining middle. In that case its LCS contribution is constant and
cannot change a middle choice. Otherwise the suffix stays in the original
algorithm. For example, `A / B / A` versus `B / A / A` retains its repeated
suffix so equally valid alignments do not move a displayed edit.

The full original arrays remain available for context and scope calculations.
Trimmed lines are restored as unchanged operations with original indices before
hunks are built. No task evidence, prompts, captures, or execution rules change.

The golden fixtures in `Tests/Fixtures/change-lens-diff-cases.json` were captured
from the implementation at `ea537b2`. They cover repeated paragraphs, ambiguous
suffixes, insertions/deletions at document and scope boundaries, normalized line
endings, Unicode, empty text, and creation. Tests compare complete hunks, line
numbers, changed flags, affected baseline ranges, and scope warnings. Run them
with:

```sh
swift test --package-path ProjectFiles --disable-sandbox --filter AgentTaskChangeLens
```

Offline differential validation also compared the actual Swift implementations
on all 16,129 pairs of two-symbol texts up to six lines, preserving every hunk.
An optimized standalone Swift benchmark over five 1,000-line comparisons measured
13.35 ms before versus 0.74 ms after for unchanged text, and 13.42 ms versus
0.82 ms for a single middle-line replacement with a disjoint suffix. These are
synthetic measurements, not timing requirements. That localized fixture reduces
the matrix from 1,002,001 cells to four; unchanged text allocates no matrix.

Correction-passage matching compares an existing source slice with the selected
lines using `elementsEqual`, after checking both supplied adjacent anchors.
It creates no per-position candidate arrays. Exact line equality, boundary
handling, and rejection immediately after a second valid occurrence are
unchanged. Offline comparison against `0e7168e` matched all 15,120 combinations
of short repeated-line texts, passages, and anchors. A 125,013-byte fixture with
1,000 repeated paragraphs measured 31.25 ms before versus 18.70 ms after across
20 checks in an optimized standalone Swift build. The previous method created
9,993 candidate arrays per check; the new method creates none, and only one
anchor pair in that fixture reaches the passage comparison. Timing is descriptive,
not a regression threshold. The focused suite also covers overlapping matches,
Unicode, whitespace, CRLF, empty/invalid passages, and document boundaries.
