# gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools directly.

Available gstack skills:
- `/office-hours` - Office hours / Q&A session
- `/plan-ceo-review` - CEO review of a plan
- `/plan-eng-review` - Engineering review of a plan
- `/plan-design-review` - Design review of a plan
- `/design-consultation` - Design consultation
- `/design-shotgun` - Rapid design generation
- `/design-html` - HTML design generation
- `/review` - Code review
- `/ship` - Ship / deploy workflow
- `/land-and-deploy` - Land and deploy
- `/canary` - Canary deployment
- `/benchmark` - Benchmarking
- `/browse` - Web browsing (use this for ALL web browsing)
- `/connect-chrome` - Connect to Chrome browser
- `/qa` - QA testing
- `/qa-only` - QA only (no fixes)
- `/design-review` - Design review
- `/setup-browser-cookies` - Setup browser cookies
- `/setup-deploy` - Setup deployment
- `/retro` - Retrospective
- `/investigate` - Investigation / research
- `/document-release` - Document a release
- `/codex` - Codex agent
- `/cso` - CSO review
- `/autoplan` - Automatic planning
- `/careful` - Careful mode
- `/freeze` - Freeze changes
- `/guard` - Guard / protect
- `/unfreeze` - Unfreeze changes
- `/gstack-upgrade` - Upgrade gstack
- `/learn` - Learning / documentation

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
