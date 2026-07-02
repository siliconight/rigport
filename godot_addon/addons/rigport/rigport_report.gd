@tool
class_name RigPortReport
extends RefCounted
## Renders a RigPortValidator result as the Character Readiness Report and
## saves it under res://rigport_reports/ as Markdown + JSON.

const REPORT_DIR := "res://rigport_reports"


static func to_markdown(r: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("# RigPort Character Readiness Report")
	lines.append("")
	lines.append("Character: %s" % r.get("character", "?"))
	lines.append("Preset: %s" % r.get("preset_name", "?"))
	lines.append("Date: %s" % Time.get_date_string_from_system())
	lines.append("")
	lines.append("## Score")
	lines.append("")
	lines.append("%d%%" % r.get("score", 0))
	lines.append("")
	lines.append("## Result")
	lines.append("")
	lines.append("%s." % r.get("band", "?"))
	for section: Array in [["Pass", "passes"], ["Warnings", "warns"], ["Failures", "fails"]]:
		lines.append("")
		lines.append("## %s" % section[0])
		lines.append("")
		var items: Array = r.get(section[1], [])
		if items.is_empty():
			lines.append("- None")
		else:
			for msg: String in items:
				lines.append("- %s" % msg)
	lines.append("")
	return "\n".join(lines)


static func save(r: Dictionary) -> String:
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_DIR))
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("RigPort: cannot create %s (err %d)" % [REPORT_DIR, err])
		return ""
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var base := "%s/%s_%s" % [REPORT_DIR, str(r.get("character", "character")).validate_filename(), stamp]

	var md := FileAccess.open(base + ".md", FileAccess.WRITE)
	if md == null:
		push_error("RigPort: cannot write report to %s.md" % base)
		return ""
	md.store_string(to_markdown(r))
	md.close()

	var js := FileAccess.open(base + ".json", FileAccess.WRITE)
	if js != null:
		js.store_string(JSON.stringify(r, "  "))
		js.close()
	return base + ".md"
