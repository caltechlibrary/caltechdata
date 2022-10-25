# Flask survival guide: Mike's random tips for dealing with Flask 

InvenioRDM is basically a big Flask-based application. So, if you're trying to figure out how the InvenioRDM code works, you're going to have to understand a lot about how Flask works. Here are explanations about things that were not obvious to me when I first started. Hopefully this information will help save you time and frustration.


## Figuring out `url_for`

Throughout Invenio, you will find code that uses Flask's [`url_for()`](https://flask.palletsprojects.com/en/2.2.x/api/#flask.Flask.url_for) function. Here's an example:
```python
return url_for("invenio_oauthclient.login", remote_app="github")
```

As you might expect based on its name, `url_for()` returns a URL. The question you will have at some point is, _how is that URL constructed_? Where is it defined in the codebase?

Figuring this out mainly requires that you interpret the first argument in the call to `url_for`, possibly in combination with the parameters (in this case, `remote_app` &ndash; see below). The first argument to `url_for` is what Flask calls an "endpoint". It's a string usually with a `.` character in it. Parse it like this:
* The first part of the string, before the `.`, is the name of a Flask _blueprint_. Let's say this part of the string is "A". This means you need to look in the codebase for files that import `Blueprint` from Flask, and then from that set of files, look for a file that contains a call to `Blueprint` in which the first argument is "A". Watch out that a lot of Invenio code is written in the following way, where "A" is not on the same line as `Blueprint`, so a simple-minded grep will not be enough to find it:
    ```python
    blueprint = Blueprint(
        "invenio_oauthclient",
        __name__,
        url_prefix="/oauth",
        static_folder="../static",
        template_folder="../templates",
    )
    ```
* The part of the string after the `.` is the name of a function associated with a route defined for the blueprint. If the endpoint string is "A.B", then "B" is the name of a Python function attached to a route. For the example given at the beginning, this turns out to be the following code in the file where the blueprint "invenio_oauthclient" is defined:
    ```python
    @blueprint.route("/login/<remote_app>/")
    def login(remote_app):
        """Send user to remote application for authentication."""
        try:
            return _login(remote_app, ".authorized")
        except OAuthRemoteNotFound:
            return abort(404)
    ```

The parameter `remote_app` in this example turns out to be important to disambiguating the possibilities in the blueprint code: in the file containing the definition of route `/login/<remote_app>/`, there is _also_ a definition for `/login`. But for the case given at the beginning of this example, with the parameter given to `url_for()`, the relevant route is `/login/<remote_app>/` rather than `/login`.
