# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Converter: `db/schema.rb` (+ extra schema files) and `app/models` → qdbd schema files,
  parsed statically with Prism.
- Relationships from `add_foreign_key` / `t.references` and from `belongs_to`, `has_many`,
  `has_one`, `has_and_belongs_to_many` (class_name, foreign_key, primary_key, join_table,
  STI, concerns, `with_options`, namespaces, project inflections).
- Documentation notes for composite/expression/partial indexes, check constraints, enums,
  polymorphic associations (incl. Active Storage), generated columns, STI, attachments.
- `.rails2qdbd.yml`: output, schemas, models, inflections, exclude, groups.
- CLI `rails2qdbd` with `--check` for CI.
