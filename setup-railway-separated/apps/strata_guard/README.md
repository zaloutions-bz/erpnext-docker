# strata_guard

ERPNext's query reports (General Ledger, Profit and Loss, Balance Sheet and the
rest) take the company as a filter and don't check it against the caller's
Company User Permissions. On a site shared by several organisations, one
organisation's API user could read another's ledger by naming its company.

This app overrides the report entry points that return data:

- `frappe.desk.query_report.run`
- `frappe.desk.query_report.export_query`
- `frappe.core.doctype.prepared_report.prepared_report.make_prepared_report`

Each refuses, with `PermissionError`, a request whose `company` filter names a
Company the caller may not read (`frappe.has_permission("Company", "read")`),
then hands everything else to the original method unchanged. A request without
a `company` filter passes through; those reports refuse it themselves.

Built into the image by `setup-railway-separated/Dockerfile` and installed on the
site at boot by `railway-cmd.sh`. Design: strata-app
`openspec/changes/erpnext-automatic-setup` (D5).
