app_name = "strata_guard"
app_title = "Strata Guard"
app_publisher = "Zaloutions"
app_description = "Refuses ERPNext report requests for a Company the caller may not read"
app_license = "MIT"
required_apps = ["frappe"]

# Frappe uses the last override registered for a method (frappe.override_whitelisted_method).
override_whitelisted_methods = {
    "frappe.desk.query_report.run": "strata_guard.report_guard.run",
    "frappe.desk.query_report.export_query": "strata_guard.report_guard.export_query",
    "frappe.core.doctype.prepared_report.prepared_report.make_prepared_report": "strata_guard.report_guard.make_prepared_report",
}
