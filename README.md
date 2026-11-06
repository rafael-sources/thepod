# thePod

Todo el ecosistema thePod en un solo repositorio, con la historia completa de cada parte.

| Carpeta | Qué es |
|---|---|
| `apps/pre` | prePod — preproducción (podcast, episodios, guion, invitados, calendario) |
| `apps/prod` | prodPod — estudio en vivo (grabación remota, soundboard, director) |
| `apps/ama` | amaPod — preguntas en vivo con la audiencia |
| `apps/post` | postPod — edición y publicación (web) |
| `apps/thepod` | thePod — landing, cuenta, planes, descargas y el manual |
| `mac` | thePod para Mac — la app nativa (Swift, Apple silicon) |

Cada app es un servicio Flask independiente con su `requirements.txt` y sus `tests/`;
la app de Mac se genera con `xcodegen` desde `mac/project.yml`. Historia: este repo nació el 5 de
noviembre de 2026 uniendo los cinco repos originales (`postpod`, `prepod`, `prodpod`, `amapod`, `thepod`)
con todos sus commits; las ramas de cada uno siguen aquí con el prefijo de su app (`prod/teleprompter`,
`post/feat/macos-app`…).
