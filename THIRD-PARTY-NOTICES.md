# Third-party notices

Swift components depend only on Apple system frameworks and system SQLite. These are supplied by the operating system; no Apple framework or SQLite binary is redistributed in this source snapshot. Shared lifecycle/configuration/remote-copy files are the author's own source copies, distributed under this repository's MIT license.

The Python cloud core imports FastAPI (MIT), Starlette (BSD-3-Clause), Pydantic (MIT), Uvicorn (BSD-3-Clause), Jinja2 (BSD-3-Clause), markdown-it-py (MIT), and their transitive dependencies. Development tests additionally use HTTPX (BSD-3-Clause). `service/requirements*.txt` declare the installation requirements; packages and their license files are installed by the user and are not vendored or redistributed here. Before distributing a binary/container, retain the license notices from each installed package's metadata, including transitive dependencies.

Original icons and demo fixtures are included under the main MIT license. No third-party fonts, notification content, images from user messages, or Apple exported data are included.
