extends RefCounted
## Repository implementations expose path, exists(), load_world(), save_world().
## save_world succeeds only after validated durable publication; load_world returns
## {world,recovered,migrated} or {error}. Tokens remain private to each adapter.
## JSON uses a file fingerprint; SQLite uses an atomic expected commit revision.

var path := ""

func exists() -> bool:
	return false

func load_world() -> Dictionary:
	return {"error": "Repository is not configured."}

func save_world(_world: Dictionary) -> Dictionary:
	return {"error": "Repository is not configured."}
