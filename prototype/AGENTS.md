# Working on Region Lab

- Keep portable world records independent from Godot nodes. Explain semantic changes in `docs/opensim-data-mapping.md`.
- Route UI and automation mutations through `world_service.gd`; preserve validation, stable IDs, revisions and explicit error results.
- Accept data through the documented command set. Do not execute generated script text or deserialize native Godot resources supplied by callers.
- Make one bounded change with an observable acceptance case. Use existing native engine tests for schema, persistence and real physics.
- For UI changes, run `tools/Test-RegionLab.ps1 -Visual` and inspect actual rendered screenshots. Compilation or a zero exit status alone is not evidence of usability.
- Keep tests in unique scratch directories. Do not overwrite user worlds with fixtures. Keep engine downloads and generated caches out of commits.
- Report what ran, what passed and what remains unsupported. This prototype is local and single-user; it is not a Firestorm-compatible server or a complete OpenSim replacement.
