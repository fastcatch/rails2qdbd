# frozen_string_literal: true

module Rails2qdbd
  # The intermediate representation shared by every stage. It knows neither Rails
  # nor qdbd syntax, so new sources (structure.sql, live reflection) and new writers
  # can plug in without touching the rest.
  module Catalog
    # Struct with keyword arguments and per-member defaults (procs build fresh objects).
    def self.record(*members, **defaults, &body)
      Struct.new(*members, keyword_init: true) do
        define_method(:initialize) do |**attrs|
          unknown = attrs.keys - members
          raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" if unknown.any?

          values = defaults.to_h { |key, value| [key, value.respond_to?(:call) ? value.call : value] }
          super(**values, **attrs)
        end
        class_eval(&body) if body
      end
    end

    Column = record(:name, :type, :null, :default, :limit, :precision, :scale, :array, :comment,
                    :generated, :enum_values, null: true, array: false)

    Index = record(:columns, :expression, :unique, :where, :name, columns: -> { [] }, unique: false) do
      # Only these can be expressed with qdbd's column keywords (UNIQUE / INDEX).
      def single_column?
        columns.size == 1 && expression.nil? && where.nil?
      end
    end

    # checks: check-constraint expressions, kept as documentation.
    Table = record(:name, :columns, :primary_key, :indexes, :checks, :comment, :path, :line,
                   columns: -> { [] }, primary_key: -> { [] }, indexes: -> { [] }, checks: -> { [] }) do
      def column(name)
        columns.find { |column| column.name == name }
      end

      def index_on(column_name)
        indexes.find { |index| index.single_column? && index.columns.first == column_name }
      end
    end

    ForeignKey = record(:from_table, :from_column, :to_table, :to_column)

    Schema = record(:tables, :foreign_keys, :enums, :version,
                    tables: -> { {} }, foreign_keys: -> { [] }, enums: -> { {} })

    Association = record(:macro, :name, :options, :path, :line, options: -> { {} })

    # primary_key: a column name, or an Array for a composite key.
    Model = record(:name, :superclass, :abstract, :table_name, :primary_key, :associations, :enums,
                   :attachments, :includes, :path, :line,
                   abstract: false, associations: -> { [] }, enums: -> { {} }, attachments: -> { [] },
                   includes: -> { [] })

    # cardinality: :many_to_one or :one_to_one; source: :database or :model.
    Relationship = record(:from_table, :from_column, :to_table, :to_column, :cardinality, :source,
                          cardinality: :many_to_one)

    Diagnostic = record(:severity, :message, :path, :line, severity: :warning) do
      def to_s
        location = [path, line].compact.join(":")
        location.empty? ? "#{severity}: #{message}" : "#{location}: #{severity}: #{message}"
      end
    end
  end
end
