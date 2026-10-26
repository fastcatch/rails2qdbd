"""Compile QuickDBD schema files with qdbd's own parser and print the model as JSON.

Used by the Ruby tests to assert what qdbd actually understood (defaults, nullability,
relationships, documentation comments), not just that `qdbd check` passed.
Usage: python qdbd_compile.py FILE [FILE ...]
"""

import dataclasses
import json
import sys

from quickdbd_cli.parser import compile_sources

sources = [(path, open(path, encoding="utf-8").read()) for path in sys.argv[1:]]
schema = compile_sources(sources)
print(json.dumps(dataclasses.asdict(schema), default=str))
