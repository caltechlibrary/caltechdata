"""Additional views."""

from flask import Blueprint
from invenio_pages.views import create_page_view

#
# Static pages
#
# Pages listed in app_data/pages.yaml become rows in invenio-pages'
# pages_page table (via `invenio rdm pages create`) and are edited through
# /administration/pages. Having a row is not enough to serve the URL.
#
# invenio-pages registers page URLs lazily, out of its own 404 handler
# (invenio_pages.views.handle_not_found, installed by
# InvenioPages.wrap_errorhandler during init_app). invenio-theme's init_app
# runs later and calls app.register_error_handler(404, page_not_found), which
# replaces that handler outright instead of wrapping it. So invenio-pages
# never looks a page up and never adds the rule, and the page 404s while the
# admin panel still lists it. See caltechlibrary/caltechauthors#178, where
# this was diagnosed on CaltechAUTHORS.
#
# Registering the rules explicitly avoids depending on extension load order,
# and is what invenio-pages' create_page_view docstring shows.
#
# Keep this tuple in step with app_data/pages.yaml. A URL listed here with no
# matching row 404s from render_page, and a row whose URL is not listed here
# stays unreachable.
STATIC_PAGE_URLS = ("/storage",)


#
# Registration
#
def create_blueprint(app):
    """Register blueprint routes on app."""
    blueprint = Blueprint(
        "caltechdata_site",
        __name__,
    )

    for url in STATIC_PAGE_URLS:
        # create_page_view() names every view it returns "_view", so each rule
        # needs its own endpoint; left to Flask's default they would all get
        # the same one and the second registration would raise.
        blueprint.add_url_rule(
            url,
            endpoint="static_page{}".format(url.replace("/", "_")),
            view_func=create_page_view(url),
        )

    return blueprint
