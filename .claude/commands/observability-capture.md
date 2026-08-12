---
description: Capture the README images and the walkthrough of the observability stack, driving a real browser with judgment, and refusing to publish anything it has not verified.
---

Read `skills/observability-capture/SKILL.md` in this repository and follow it
exactly to capture the images and the walkthrough.

The skill is the single source of the instruction. Do not improvise a capture of
your own, and do not fall back to driving the browser blind when a selector does
not match. Follow its rules: use an isolated browser session and never attach to
the user's own browser, run the leak check before any frame, confirm the stack
holds data in the window you are capturing, snapshot before you click, look at
every frame you keep, and refuse rather than publish a view you could not
verify.

Report the path, the viewport, and what each frame shows. Do not commit the
images unless the user asks.
