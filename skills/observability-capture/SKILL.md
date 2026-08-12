---
name: observability-capture
description: Capture the README images and the walkthrough recording of this repository's observability stack, driving a real browser with judgment rather than a fixed script. Use when a user asks their agent to "recapture the screenshots", "update the dashboard image", "record the walkthrough", or run the /observability-capture entry point. Confirms the stack holds publishable data, drives Grafana and MLflow through whatever overlays the installed versions show, asserts each view before it keeps a frame, and refuses to capture data it has not been told is publishable.
---

# Capture the images and the walkthrough

You are producing the images a stranger sees first. They go into a public
README. A wrong frame is not a small defect: it can publish a person's prompt,
a repository name, or a browser tab that was never yours to photograph.

The parts that must not vary stay in the scripts. You do the part that changes:
finding the view, clearing whatever the interface put in front of it, and
judging whether what you see is worth keeping. Read the whole skill before you
act.

## Why this is not a script

A script did this job before and shipped a wrong image while reporting success.
Two reasons, and both apply to you.

The interfaces move. Grafana and MLflow both add panels, popovers, and side
panels between releases. A selector written against last month's interface does
not fail loudly. It matches nothing, the step is skipped, and the capture
continues against the wrong view.

Judgment is required. "The dashboard is populated" is not a selector. Neither
is "this conversation shows the structure well". You have to look.

## The rules that bind you

These rules hold for every step. Do not break one to finish faster.

* You **MUST** pass `--session "$(date +%s)-capture"` on every single
  `agent-browser` command, including `eval`. A command without it runs against a
  different session and can act on a window that is not yours.
* You **MUST NOT** pass `--cdp`, and you **MUST NOT** attach to a browser the
  user is already using. Attaching inherits their tabs and their logins. An
  agent doing this photographed a user's mail, including health information,
  into a file on disk. An isolated session cannot do that.
* You **MUST** run this repository's leak check before any frame is taken, and
  you **MUST** stop if it refuses. It is the only control that decides what is
  safe to publish. Never widen it to make a capture succeed.
* You **MUST** inventory every store you are about to photograph, and not only
  the ones the check reads. The check told the truth about the stores it read
  and said nothing about a third one that the capture publishes from. Ask of each
  image: which store fills this view, and has anything confirmed what is in it.
* You **MUST** set the viewport explicitly before any capture. Never inherit the
  driver's default.
* You **MUST** confirm that data is present in the captured window before you
  capture. A stack that has been idle shows empty panels, and an empty panel is
  a failed capture, not a picture of a quiet day.
* You **MUST** look at every frame you keep and state what it shows. A frame you
  have not looked at is not evidence.
* You **MUST NOT** keep or commit a frame that shows anything outside the stack.
  Delete it, then say so.
* You **MUST** ask before capturing data marked as imported rather than
  synthetic. That data is real work with identity removed, not invented values.

## What you need before you start

Check these and stop if one is missing.

1. `agent-browser` is on the path. Run `agent-browser skills get core` and read
   it. It ships with the binary, so it describes the installed version. This
   skill does not restate the snapshot-and-ref loop; that skill owns it.
2. `ffmpeg` is on the path, if you are recording. Without it, still images still
   work, so degrade rather than stop.
3. The stack answers. Run `scripts/stack.verify.sh`.
4. The stack holds data in the window you will capture. See below.

## Step 1: confirm there is something to photograph

This is the check most likely to be skipped and most likely to waste a run.

Telemetry ages out of the capture window. A stack that was populated last week
shows "No data" on every panel today.

The three stores do not age alike, and this has already caused a near miss. The
metric and log stores drop out of the window overnight. MLflow does not: a
conversation written days ago is still the first row of the list, long after the
data that cleared it has gone. So a clean check on two stores is not a clean
check on the third.

Confirm before you drive anything:

```bash
EDGE_PORT=$(grep -E '^\s*EDGE_PORT' .env | cut -d= -f2 | tr -d ' ')
curl -sG "http://127.0.0.1:${EDGE_PORT}/prometheus/api/v1/query" \
  --data-urlencode 'query=sum(last_over_time(claude_code_session_count_total[6h]))'
```

An empty result means the window is empty. Refresh the data first, with
`scripts/demo.seed.sh` for synthetic values or `scripts/transcript.import.sh`
for imported sessions, then check again.

## Step 2: run the leak check

Run `scripts/capture.screenshots.sh` when the default synthetic data is what you
want captured. It performs the leak check itself and refuses before any frame if
the stack holds telemetry it was not told is publishable.

Drive the browser yourself only when that script cannot reach the view you need.
When you do, run the leak check first anyway, and stop if it refuses.

## Step 3: the dashboard

Open the dashboard in kiosk mode, so no navigation chrome appears in the frame.
The URL carries the time range and the template variables, so you do not have to
set them in the interface.

Two facts govern the viewport, both measured on 2026-08-06 against Grafana
13.1.1. Re-measure them; they will move.

* The page is about **2500 pixels tall at 1440 wide**. It does not fit one
  screen.
* Grafana **stops rendering panels that are off screen**. A capture that scrolls
  therefore photographs empty panels.

So set a viewport tall enough for the whole page instead of scrolling. Confirm
the height rather than assuming it:

```bash
AB eval 'JSON.stringify({h: document.documentElement.scrollHeight})'
```

Before you keep the frame, assert the view:

* Count the panels that say "No data". The count must be zero.
* Confirm all four rows are present: Overview, Cost and tokens, Activity and
  outcomes, Conversation and traces.
* Confirm the numbers are not all zero.

If any of those fails, fix the cause. Do not keep the frame.

## Step 4: MLflow, the part that needs judgment

MLflow puts things in front of the view, and the set changes between releases.
Do not work from the list below. Work from a snapshot.

Take a snapshot first. On a first load you may find that the **only** interactive
elements are the ones belonging to an overlay. That is the tell: everything else
is behind it.

Observed on 2026-08-07 against MLflow 3.15.0, as an example of the kind of thing
you will find, not as a list to trust:

* A guidance popover with "Got it" and "Close guidance". On first load these were
  the only two interactive elements on the page.
* An Assistant side panel that covers roughly a quarter of the width. It answers
  to its accessible name, so `find role button click --name "Close"` closes it.
* A "New feature" tooltip on the trace header. It survives Escape, a click
  elsewhere, a tab change, and a scroll, and it does not time out.

**Prefer preventing an overlay to dismissing one.** MLflow records what a user
has already seen in `localStorage`, under keys named for the feature. Setting one
before you load makes the session behave like a returning one, and a popover that
never renders cannot intercept a click. Look at the keys and choose:

```bash
AB eval 'JSON.stringify(Object.keys(localStorage))'
```

Clear what you find, re-snapshot after each change, and keep going until the
view is clean. Refs go stale the moment the page changes.

**Know when to stop.** The tooltip above has no stable handle: no role, no stable
class, no persisted key. The only way to remove it is to match its text, which is
the brittle handle this whole approach exists to avoid. It is small, it sits in a
corner, and it costs the reader nothing. Leaving a known artifact and naming it
beats a fragile hack that breaks silently on the next release.

### Choosing which trace to open

This is the judgment the script could not make. The list is ordered by time, so
the top row is whatever was written last, which is often the least interesting
one.

Open a trace that shows the structure the stack exists to show:

* More than one turn.
* A tool call nested under a turn.
* A subagent span, where the data has one. Nothing else in the stack shows an
  agent delegating.

A trace with one turn and no nesting is a worse picture, even though it is a
valid trace. Look at two or three before you choose.

### Before you keep the frame

* The span tree is expanded enough to show the nesting. Spans are collapsed by
  default, and a collapsed tree shows nothing worth seeing.
* No overlay covers any part of the frame.
* The content is publishable. If it is imported rather than synthetic, you have
  already asked.

## Step 5: the walkthrough recording

Record only when the point is a transition: moving between views, a panel
filling in, a trace expanding. A still image proves an end state better than a
video does, and costs far less to review.

### What to show, and in what order

The walkthrough has one job: make someone want to run this. It is not a tour of
the interface, and it is not a feature list. Four beats, and the order is the
argument, because each one answers the question the previous one raises.

| Beat | View | The question it answers |
|---|---|---|
| 1 | Dashboard, Overview row | What are my agents costing me? |
| 2 | Dashboard, Delegation row | Where did that go? |
| 3 | Grafana trace waterfall | What happened inside one session? |
| 4 | MLflow conversation | What did it actually say? |

The arc zooms in: a number, then a breakdown, then one session, then one
sentence. A viewer who stops after any beat has still learned something true.

Beat 3 is the one that earns attention. A coding agent drawn as a distributed
trace, with tool calls and subagents on one timeline, is the thing nobody
expects to see. Give it the most time.

Two things to leave out, and the reason matters more than the list. **Anything
that is a fix rather than a capability** does not belong: it is interesting to
the maintainer and meaningless to a newcomer. **Anything requiring explanation
to be impressive** does not belong either, because a silent recording cannot
explain. If a beat needs a caption, it is the wrong beat.

Hold each view still long enough to read. A view that appears and moves on
before the eye lands on it is worse than not showing it. Roughly: a headline
number needs two seconds, a chart with labels needs four, a waterfall needs
longer because the viewer is reading structure rather than a value.

Set the viewport before you start recording, or the video will not match it.
Give `record start` an absolute path.

Then review your own recording before you keep it. Cut frames and look at them:

```bash
ffmpeg -ss 0 -to 5 -i /abs/run.webm -vf fps=10 -frame_pts 1 /abs/frames/f_%05d.png
```

The recording runs at 10 frames per second, so one frame is 100 milliseconds.
You cannot report anything that falls between two frames.

Look for the failures a recording introduces and a still does not: a panel still
loading, a cursor parked over a tooltip, an overlay that opened mid-run, a
transition that happened too fast to read.

**Review with a contact sheet, not frame by frame.** One tiled image shows the
whole recording at a glance and costs a single look:

```bash
ffmpeg -v error -i /abs/run.webm -vf "fps=1/3,scale=300:-1,tile=8x4" -frames:v 1 /abs/contact.png
```

At one frame per three seconds, eight per row, each row is 24 seconds. That is
enough to find where each beat starts and where the dead time is.

### Record loose, then cut

Do not try to record the finished timing. Every driver command carries seconds
of its own overhead, so a recording aimed at 35 seconds lands near 90, and the
overhead falls between the beats rather than inside them.

Record with generous holds, then cut the segments you want and concatenate. Two
things follow from this, and both are improvements rather than compromises:

* Overlay dismissals, stray clicks, and navigation can happen on camera, because
  those frames end up on the cutting-room floor. You no longer have to fight an
  interface into a clean state while recording.
* Pacing becomes a decision rather than an accident. You choose how long each
  beat holds after seeing what it looks like.

```bash
ffmpeg -v error -ss 28 -t 11 -i run.webm -c:v libx264 -preset slow -crf 22 \
  -pix_fmt yuv420p -r 10 -an seg3.mp4
# then: printf "file 'seg1.mp4'\n..." > concat.txt
ffmpeg -v error -f concat -safe 0 -i concat.txt -c copy walkthrough.mp4
```

### The animated fallback

Produce a GIF as well as the video, because many surfaces that render Markdown
do not play video. Generate a palette first: a naive conversion destroys small
text, which is most of what a screen recording contains.

```bash
ffmpeg -v error -i walkthrough.mp4 -vf "fps=8,scale=800:-1:flags=lanczos,palettegen=stats_mode=diff" palette.png
ffmpeg -v error -i walkthrough.mp4 -i palette.png \
  -lavfi "fps=8,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  walkthrough.gif
```

Eight frames per second at 800 wide keeps a 37 second walkthrough near 3 MB and
the text readable. Check the size before committing; a GIF that dwarfs the
repository is not a fallback, it is a problem.

## Step 6: report

State, for each artifact:

* The path you wrote.
* The viewport width and height.
* What the frame shows, in your own words, having looked at it.
* Whether the data was synthetic or imported.

Then stop. Do not commit the images unless the user asks. They are the ones who
decide what gets published.

## When you cannot get a clean frame

Say so, and say what blocked you. A described defect the user can act on is a
better outcome than a frame that looks fine and is wrong.

Do not widen the leak check. Do not capture a view you could not verify. Do not
attach to the user's browser because the isolated session was inconvenient.
