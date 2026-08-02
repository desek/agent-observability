---
description: Uninstall the observability wiring this agent added, restore any replaced value, and confirm export has stopped.
---

Read `skills/observability-install/SKILL.md` in this repository and follow its
"Uninstall" section exactly.

Remove only the keys the install added. Restore any value the install replaced,
from the backup it wrote. Back up and validate each settings file as you go. Then
drive one turn and confirm no new signal arrives, which is the proof that export
has stopped.
