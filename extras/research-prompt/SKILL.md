---
name: research-prompt
description: Use when current information from the web would help a task and the session has no web access, or the user prefers not to send project context to a web search: about to reach for WebSearch or WebFetch, about to answer a market, adoption, vendor-behavior or standards question from training data, or noticing a knowledge gap mid-task. Also use when the user asks to "research X" or "find out the current state of X". Drafts a self-contained research prompt the user runs in a web-enabled AI tool. Not for library, framework or SDK documentation, which a documentation server such as Context7 answers directly.
---

# Research hand-off prompts

Web research runs outside this session. You draft a hand-off prompt; the user pastes it into a web-enabled AI tool and brings the report back. This keeps project context out of external services and keeps the evidence neutral.

The need for research usually comes up mid-task, not as a request. When it does, the action is drafting a prompt, not searching.

## Do not search the web yourself

Do not use WebSearch, WebFetch or a web research skill for this, even when one appears available. In the agent-container-kit sidecar both tools are denied by policy; elsewhere the hand-off is still the route, for the privacy and neutrality reasons above.

| Thought | What to do instead |
|---|---|
| "This question suits a web research tool" | Draft the hand-off prompt. |
| "A round trip through the user is slower" | The hand-off is the fast path; blocked tools waste the session. |
| "WebSearch seems to work, so it must be allowed" | Availability is not permission. Draft the prompt. |
| "I'll just check one fact" | One fact is a research need. Draft the prompt, or ask the user. |

## What a documentation server answers instead

If the session has a documentation server such as Context7, use it directly for anything a library's official docs answer: API syntax, configuration, migration, current idioms. Everything that needs the open web (market data, adoption evidence, vendor policy, standards status, competitor information, news, anything contested) goes through a hand-off prompt.

## Process

1. **Intake.** Ask the user what decision the research serves, and whether they want the researcher's recommendations. The default is no: evidence only, and the user decides. If the scope is unclear, ask two or three questions before drafting.
2. **Prior research.** Ask the user where the project keeps research reports, the first time it comes up in a session. Search that folder for reports on the topic and note each one's date. A current, on-point report is referenced, not commissioned again. An on-point but older report gets a delta prompt: "a prior review as of [month year] covered X; report what has changed since." Treat anything time-sensitive as out of date after about three months.
3. **Draft the prompt** to the contract below.
4. **Deliver it as one fenced markdown block at the end of your message**, self-contained, since the external tool has no project context. After it, say where the report will be filed, and save a copy of the prompt in that folder's `prompts/` subfolder as `prompts/YYYY-MM-DD-<short-title>-prompt.md`, so a later delta prompt knows exactly what was asked and when.
5. **When the report comes back**, propose filing it in the research folder as `YYYY-MM-DD-<short-title>.md`, then offer to go through it with the user.

## The prompt contract

Every hand-off prompt has these parts, in this order:

1. **Title:** `# Research request: <topic> (evidence inventory)`, or the genre that fits (landscape survey, primary-source review, changes since a date).
2. **Role and ground rules:** the researcher compiles a neutral evidence inventory for someone else's decision. No recommendations, no prioritization, no "should" framing, unless the user asked for recommendations in step 1, and then evidence and recommendations go in separate sections. Primary sources preferred; every claim dated; three labeled evidence tiers (documented mechanism, vendor statement, community speculation); contested points left unresolved; "no public evidence" and negative findings are valid answers.
3. **Context block:** minimal, marked "for relevance filtering only; do not tailor advice." Describe the subject generically, for example "a small business's content site, statically rendered, low page count." Never include names, domains, email addresses, employers, client names, locations or account handles. If a detail would identify the person or project, generalize it.
4. **The questions:** phrased as "what is the current evidence about X," never "should we do X" or "confirm that X is worth it." The prompt does not reveal which answer is hoped for.
5. **Coverage checklist:** flat lists per category, introduced as "not endorsements; treat every item with equal skepticism." Mix the items that matter among peers nobody asked about, and tell the researcher to add items the list is missing.
6. **Output format:** state the report's outline as "exactly these sections, in this order, no others," fitted to the research. A default to adjust:
   1. Title: `<topic>: <genre> (as of [date])`
   2. Summary table: item, status, evidence tier, and the columns the question needs
   3. Key findings: a handful, numbered, each with its evidence tier
   4. One entry per item, grouped by the checklist's categories, with mechanism, evidence and dates, status, cost, how to measure, risks and sources
   5. Conflicting or thin evidence: every claim a primary source does not confirm
   6. Dated source list

   Whatever the outline, keep a summary up front, a thin-evidence section, dated sources and no advice sections. If the user asked for recommendations, they form one separate final section.

   Add these two lines to the prompt word for word: "The ground rules above govern how you work; they must be invisible in the deliverable: do not restate them, reference them, or add sections explaining what the report deliberately omits." and "If your platform requires a recommendations or next-steps closer, it may contain only self-serve verification methods (how a reader could independently check the contested claims), never advice." Some research tools add a recommendations section on their own; the second line gives that a form that is not advice.

## Before you deliver the prompt

- [ ] No name, domain, email, employer, client, location or handle anywhere in it
- [ ] No request for recommendations, unless the user asked for them, and then in separate sections
- [ ] Questions ask for evidence, not decisions
- [ ] The items that matter are indistinguishable from the others in the coverage lists
- [ ] An outline is stated ("exactly these sections, no others"), with an as-of date, a summary up front, evidence tiers, a thin-evidence section and dated sources
- [ ] Both word-for-word lines are present
- [ ] No reference to project files, skills or this conversation
- [ ] Delivered as one fenced block at the end of the message
