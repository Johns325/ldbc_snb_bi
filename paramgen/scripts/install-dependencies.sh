#!/usr/bin/env bash

# In a virtualenv, `pip --user` fails because user site-packages are hidden.
# Install into the currently active environment instead.
python3 -m pip install duckdb pytz
