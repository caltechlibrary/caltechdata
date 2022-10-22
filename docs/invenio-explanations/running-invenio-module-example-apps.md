# Invenio module example apps

Most Invenio module's source directories have a subdirectory named `examples`. A basic Invenio module's `examples` directory has a structure and contents like this.

```
examples
├── app-fixtures.sh
├── app-setup.sh
├── app-teardown.sh
└── app.py
```

The rest of this file explains the contents and general structure of these examples directories.


## Installation

Perhaps obviously, if you are experimenting with the example code for a module, it means you have to clone the module repository to your local computer hard drive. Taking the Invenio-Logging module as an example, you would do something like this:

```sh
git clone git@github.com:inveniosoftware/invenio-logging.git
cd invenio-logging
```

Next, you need to install the module in your Python environment. There is an important detail in this step: you may need to install additional dependencies beyond the module itself.  These will be specified in a section of the module's `setup.cfg` called `[options.extras_require]`. You would do the installation like this:

```sh
pip install -e .[all]
```


## Running the example app

After the installation step above, change your shell's working directory to the `examples` subdirectory:

```sh
cd examples
```

It's worth checking the contents of the file `app.py` for explanations &ndash; sometimes Invenio module example apps have explanations in comments at the top of the file.

The general procedure for most example apps involves first running two scripts to set up the environment (e.g., by starting background services):

```sh
./app-setup.sh
./app-fixtures.sh
```

Sometimes these files don't do anything, and may be unnecessary, but the pattern of most Invenio modules is that there is an `app-setup` and `app-fixtures` script.

Next, run the app in debug mode, setting some shell environment variables first. In the simplest case,  this might be done by issuing the following shell commands:

```sh
export FLASK_APP=app.py FLASK_DEBUG=1
flask run
```

However, some examples have scripts (named something obvious like `run-app.sh`) that you must run instead.

The next step after that depends on the details of the Invenio example app. Sometimes the next step is to open a browser window on a local web address such as `http://127.0.0.1:5000/`. Hopefully the comments in the `app.py` file explain it.


## Stopping the app

The usual way that processes need to be stopped is to run the teardown script provided in the  example app's directory:

```sh
./app-teardown.sh
```
