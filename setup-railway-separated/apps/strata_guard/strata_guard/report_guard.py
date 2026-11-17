"""Report entry points that refuse a Company the caller may not read.

ERPNext's query reports take `company` as a filter and never check it against the
caller's User Permissions. Each override here checks it, then calls the original
method with the same arguments.
"""

import json

import frappe
from frappe import _
from frappe.core.doctype.prepared_report import prepared_report
from frappe.desk import query_report


def companies_in(filters) -> list[str]:
    """The company or companies a report's filters name. Unparseable filters name none."""
    if isinstance(filters, str):
        try:
            filters = json.loads(filters) if filters.strip() else {}
        except ValueError:
            return []
    if not isinstance(filters, dict):
        return []
    company = filters.get("company")
    if isinstance(company, str):
        return [company] if company else []
    if isinstance(company, (list, tuple)):
        return [c for c in company if isinstance(c, str) and c]
    return []


def assert_companies_permitted(filters) -> None:
    for company in companies_in(filters):
        if not frappe.has_permission("Company", "read", doc=company):
            frappe.throw(_("Not permitted to report on Company {0}").format(company), frappe.PermissionError)


@frappe.whitelist()
@frappe.read_only()
def run(
    report_name,
    filters=None,
    user=None,
    ignore_prepared_report=False,
    custom_columns=None,
    is_tree=False,
    parent_field=None,
    are_default_filters=True,
    js_filters=None,
):
    assert_companies_permitted(filters)
    return query_report.run(
        report_name=report_name,
        filters=filters,
        user=user,
        ignore_prepared_report=ignore_prepared_report,
        custom_columns=custom_columns,
        is_tree=is_tree,
        parent_field=parent_field,
        are_default_filters=are_default_filters,
        js_filters=js_filters,
    )


@frappe.whitelist()
def export_query():
    # The original reads its arguments from form_dict, so the check does too.
    assert_companies_permitted(frappe.local.form_dict.get("filters"))
    return query_report.export_query()


@frappe.whitelist()
def make_prepared_report(report_name, filters=None):
    assert_companies_permitted(filters)
    return prepared_report.make_prepared_report(report_name=report_name, filters=filters)
