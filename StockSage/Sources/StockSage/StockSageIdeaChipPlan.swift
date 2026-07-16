import Foundation

// MARK: - Idea-card conditional-chip density plan
//
// QA-4+F1 (density rework): the ideaCard badge row can carry up to 7 CONDITIONAL
// chips (stale, earnings, floor, held/traded [one combined slot], delta, extreme,
// confluence) plus 2 always-shown fixtures (the action badge and the EV chip,
// documented below as uncounted). Two bugs this fixes:
//   1. The old 5-chip cap counted only 5 of the 7 conditionals (confluence and,
//      by construction, the un-droppable extreme/held slots were never subject
//      to the cap) — a row could actually render 7-8 elements.
//   2. `chipsSoFar` was computed TWICE — once at the render site, once in the
//      a11y label builder — a hand-copy that could silently desync (round-B
//      note). This type is the SINGLE seam: the render site and the a11y
//      builder both call `visibleChips` and iterate the SAME returned list, so
//      desync is structurally impossible.
//
// Action badge + EV chip stay uncounted fixtures of the row — documented, not
// accidental: the action badge is the row's identity anchor (what to DO), the
// EV chip is the money figure (why); both must always be visible.
//
// Priority order (decision-relevance, info-hierarchy lens — most-important
// FIRST, so dropped chips are the ones a trader can most afford to lose):
//   1. stale     — the whole board's numbers may be wrong; overrides everything.
//   2. earnings  — binary gap risk on THIS name.
//   3. floor     — honesty badge: costs already exceed the edge.
//   4. heldOrTraded — the owner's own money/history with this name.
//   5. delta     — "New" / "was <Action>" since the last scan.
//   6. extreme   — neutral descriptive fact (at N-day high/low); most droppable,
//      pure context, never a signal.
// Confluence was ALWAYS-ON before this fix (unconditionally rendered after the
// EV chip); it now JOINS the counted set as priority 7 (lowest) — it's a
// display-only breadth read, no less droppable than "at N-day high/low".
enum IdeaChipPlan {
    /// One conditional chip's identity — render-site and a11y-label call sites
    /// switch on this so wording stays local to each (the STRINGS differ:
    /// visible chips are short labels, the a11y label is a full sentence), but
    /// the SET and ORDER of what's visible always comes from `visibleChips`.
    enum Chip: Sendable, Equatable {
        case stale
        case earnings
        case floor
        case heldOrTraded
        case delta
        case extreme
        case confluence
    }

    /// Cap on conditional chips actually shown. Action badge + EV chip are
    /// separate, always-shown fixtures — never counted against this.
    static let cap = 5

    /// Every conditional chip that WANTS to render, priority-ordered (see the
    /// type doc). Presence flags mirror the booleans already computed at the
    /// ideaCard call site — this function makes no engine calls of its own.
    static func visibleChips(stale: Bool, earnings: Bool, floor: Bool, heldOrTraded: Bool,
                              delta: Bool, extreme: Bool, confluence: Bool) -> [Chip] {
        var candidates: [Chip] = []
        if stale        { candidates.append(.stale) }
        if earnings     { candidates.append(.earnings) }
        if floor        { candidates.append(.floor) }
        if heldOrTraded { candidates.append(.heldOrTraded) }
        if delta        { candidates.append(.delta) }
        if extreme      { candidates.append(.extreme) }
        if confluence   { candidates.append(.confluence) }
        // Candidates are already in priority order (append order above matches
        // the doc's numbered list) — the cap simply truncates the tail, which
        // drops the LOWEST-priority chips first.
        return Array(candidates.prefix(cap))
    }
}
