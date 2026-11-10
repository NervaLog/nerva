---
id: P259e
date: 2026-11-10
area: Releases
amends: P147b
---

# A release that only reverts skips the 24-hour fleet soak and needs one adversarial review instead of two

Owner, 2026-11-10: rollback after the switch is a revert release (N's tree with the next release string). A release that only reverts to a released N skips the 24-hour fleet soak of the release gate and needs one adversarial review instead of two. It still quotes the fleet's tracker line from N, and the Jepsen result.

**Why.** Its code is N's, which already passed the gate with the soak and two reviews. Rollback is when an operator is most pressed, and waiting a day makes the cluster run the bad release longer.

**Cost.** A revert release has less scrutiny than the gate asks for: it relies on N's tree being byte for byte what N was, so the review checks that the diff against N is only the release string and the release notes.
