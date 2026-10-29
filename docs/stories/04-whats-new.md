# What's new

Part of the [BugKit stories](README.md). What's new was built in Context Grabber's native app first, as CG story 148. The reporting dialog and What's new are two halves of one loop: problems go to the developer, and what changed comes back to the person who reported them.

---

### User Story 030:

- **Summary:** What's new, by day, written by the build itself
- **From:** CG story 148 (#165), f3d2758
- **Status:**
  - `WhatsNew.build`, `WhatsNew.stories` and `WhatsNew.commits(fromLog:)` are verified on the host by `WhatsNewTests`:
    - by local day, newest first, one line per story per day;
    - bookkeeping commits dropped;
    - summaries taken from the stories;
    - the log text parsed.
  - `scripts/whats-new.sh` ran against a real checkout on 2026-10-10.

#### Use Case:
- **As someone** who installs a new build most days
- **I want to** see what each recent day's builds changed, in plain words, newest first
- **so that** I remember what to try, and nobody has to keep a list up to date

#### Acceptance Criteria:
- **Scenario:** The list by day
- **Given:** the last thirty days hold story commits on several days, some with status follow-ups and merges
- **When:** I open *What's new*
- **Then:**
  - I see one section per day, newest first;
  - each change appears once per story per day, with its story and issue under it;
  - there are no status or merge lines;
  - the log has `ui` open_whats_new with the days and changes.

- **Scenario:** Nothing to show
- **Given:** a build made without the project's history, or with no story change in thirty days
- **Then:** the feed is empty, there is no home row, and the list says there is nothing new, with no error

---

### User Story 031:

- **Summary:** A change opens its story
- **From:** CG #232 (5227ba9)
- **Status:** `WhatsNew.stories(fromMarkdown:file:baseURL:)` with `WhatsNewView`.
  - Verified on the host by `testEachStoryLinksToItsHeading` and `testBugKitsOwnStoriesParse`.
  - The view is verified by typecheck.

#### Use Case:
- **As someone** reading a change I do not understand
- **I want to** tap it and read its story
- **so that** I know what to try and what it should do

#### Acceptance Criteria:
- **Scenario:** A tap
- **Given:** the build passed `--base-url https://github.com/<owner>/<repo>/blob/main/docs/stories/`
- **When:** I tap a change
- **Then:** its story opens at its own heading (`#user-story-NNN`), and the log has `ui` open_story with the story and the address

---

### User Story 032:

- **Summary:** A commit that names its story only in its message, or through its issue, still shows
- **From:** CG #246 (6b1d0aa)
- **Status:** `WhatsNew.parse(subject:body:issueStories:)` with `issueStories(fromMarkdown:)`. Verified on the host by `testASubjectWithoutAStoryFindsItInTheMessageOrThroughItsIssue`.

#### Use Case:
- **As a** developer who wrote a plain subject and named the story in the body
- **I want to** have the change listed anyway
- **so that** What's new does not depend on one commit-subject style

#### Acceptance Criteria:
- **Scenario:** The story in the message
- **Given:** a commit "Cockpit: Back in the footer" whose message says "Story 200."
- **Then:** it is listed under story 200 in its own words

- **Scenario:** Through its issue
- **Given:** a commit "a stale retry no longer ends a call (#198)", where a story's Issues line lists #198
- **Then:** it is listed under that story

---

### User Story 033:

- **Summary:** Dismissed with its ✕, kept in settings
- **From:** CG story 148 (adfed5a, `WhatsNewSeenUITests`)
- **Status:**
  - `WhatsNewSeen` and `WhatsNewRow`. Verified on the host by `testTheSeenStoreHidesTheRowUntilSomethingNewer` and `testHomeRowGoesOnceSeenAndComesBackForSomethingNewer`.
  - The row is verified by typecheck. On iOS its ✕ is a 44×44 pt touch target, verified in the simulator by `whatsNewDismissIsATouchSizedTarget` (#35).

#### Use Case:
- **As someone** who has read what is new
- **I want to** hide the home row until there is something newer, but still reach the list
- **so that** the home screen holds what I open, and nothing nags

#### Acceptance Criteria:
- **Scenario:** The ✕
- **Given:** the home screen shows *What's new · Oct 5 — …*
- **When:** I open it and come back, then tap its ✕, then relaunch
- **Then:**
  - opening leaves the row;
  - the ✕ removes it, and the relaunch does not bring it back until a build with a newer change;
  - the app's settings still open the list;
  - the log has `ui` dismiss_whats_new.

### User Story 034:

- **Summary:** "Fixed in this build" shows the person their own report, under the change that fixed it
- **From:** BugKit review 2026-10-26 (V1)
- **Status:** `WhatsNewTests` covers it on the host (closing keywords, issue markers, the feed, the device match); typecheck in CI. A device check is still owed: a build with `--fixed-reports` after a `Fixes #N` commit.

#### Use Case:
- **As someone** who shook the phone to report a problem
- **I want to** see, in the build that fixes it, my own words and the day I reported it
- **so that** reporting has a visible consequence, and I know what to try again

#### Acceptance Criteria:
- **Scenario:** A fix for my report
- **Given:** the build phase runs `whats-new.sh --fixed-reports`, and a commit in the window says `Fixes #12`, where issue #12 carries my report's `<!-- bug-id:… -->` marker
- **When:** I open What's new on the device that made the report
- **Then:**
  - the change shows "Fixed in this build: “<my note's first line>” (<the day I reported it>)";
  - the home row reads "What's new · Fixed in this build: “<my note>”", for the build that fixed it only: whether or not I dismissed the row, a later build's row names its own newest change unless it fixed another of my reports (`WhatsNewSeen.fixedEarlier`, `testAFixFromAnEarlierBuildIsNotHeadlinedAgain`);
  - `ui` open_whats_new logs `fixed_reports`;
  - another device, without that report, shows the change as usual;
  - nothing leaves the device: the match is against its own `bugs.jsonl`.

- **Scenario:** No `gh`
- **Given:** `gh` is missing, signed out or offline, or takes over 20 seconds
- **Then:** the feed is built without fixed reports and the build does not fail

### Reset dismissal for a test launch

**Issues:** #16

Given a dismissed newest change, when the app constructs its retained `WhatsNewSeen` with a launch prefix and `<PREFIX>_WHATS_NEW_RESET=1`, its first read has no dismissed change. Other defaults remain intact, and `bug_hook.whats_new_reset` is true. Missing, wrong-prefix and non-`1` values preserve the dismissal. Host coverage: `whatsNewResetHookIsExplicitAndPrefixScoped`, `whatsNewResetRunsBeforeFirstReadAndPreservesOtherDefaults`.
