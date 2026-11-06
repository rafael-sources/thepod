# thePod

The entire thePod ecosystem in a single repository, with the full history of each part.

| Folder | What it is |
|---|---|
| `apps/pre` | prePod — pre-production (podcast, episodes, script, guests, calendar) |
| `apps/prod` | prodPod — live studio (remote recording, soundboard, director) |
| `apps/ama` | amaPod — live Q&A with the audience |
| `apps/post` | postPod — editing and publishing (web) |
| `apps/thepod` | thePod — landing page, account, plans, downloads and the manual |
| `mac` | thePod for Mac — the native app (Swift, Apple silicon) |

Each app is an independent Flask service with its own `requirements.txt` and `tests/`;
the Mac app is generated with `xcodegen` from `mac/project.yml`. History: this repo was born on
November 5, 2026 by merging the five original repos (`postpod`, `prepod`, `prodpod`, `amapod`, `thepod`)
with all their commits; each one's branches are still here prefixed with their app (`prod/teleprompter`,
`post/feat/macos-app`…).
