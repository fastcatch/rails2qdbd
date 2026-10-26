# frozen_string_literal: true

require "prism"
require "active_support/inflector"

module Rails2qdbd
  # Reads the db/schema.rb dump DSL statically into a Catalog::Schema.
  class SchemaParser
    include Catalog

    # Calls inside `create_table` that are not columns.
    TABLE_IGNORED = %i[exclusion_constraint unique_constraint foreign_key].freeze
    COLUMN_OPTIONS = %i[null default limit precision scale array comment].freeze

    attr_reader :diagnostics

    # inflector: anything answering #singularize and #pluralize (the project's Inflector later on).
    def initialize(inflector: ActiveSupport::Inflector)
      @inflector = inflector
      @diagnostics = []
    end

    # paths are relative to root and are reported that way; tables share one namespace.
    def parse_files(paths, root:)
      merged = Schema.new
      paths.each do |path|
        full = File.expand_path(path, root)
        raise Error, "schema file not found: #{path}" unless File.file?(full)

        schema = parse(File.read(full), path: path)
        merged.version ||= schema.version
        merged.enums.merge!(schema.enums)
        merged.foreign_keys.concat(schema.foreign_keys)
        schema.tables.each do |name, table|
          if (first = merged.tables[name])
            error(%(table "#{name}" already defined at #{first.path}:#{first.line}), path, table.line)
          else
            merged.tables[name] = table
          end
        end
      end
      merged
    end

    def parse(source, path:)
      @path = path
      @schema = Schema.new
      @pending_enums = []
      result = Prism.parse(source)
      if result.failure?
        result.errors.each { |e| error("syntax error: #{e.message}", path, e.location.start_line) }
        return @schema
      end

      statements(define_body(result.value)).each { |node| top_level(node) }
      @pending_enums.each { |column, type| column.enum_values = @schema.enums[type] }
      @schema
    end

    private

    # The block of `ActiveRecord::Schema[8.1].define(...)`; falls back to the whole program.
    def define_body(program)
      define = statements(program).find { |n| n.is_a?(Prism::CallNode) && n.name == :define && n.block }
      return program unless define

      receiver = define.receiver
      if receiver.is_a?(Prism::CallNode) && receiver.name == :[]
        version = Literal.value(receiver.arguments&.arguments&.first)
        @schema.version = version.to_s if Literal.known?(version)
      end
      define.block
    end

    def statements(node)
      body = node.respond_to?(:statements) ? node.statements : node.body
      body = body.body if body.is_a?(Prism::StatementsNode)
      Array(body)
    end

    def top_level(node)
      return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

      args, options = Literal.arguments(node)
      case node.name
      when :create_table then create_table(node, args, options)
      when :add_foreign_key then add_foreign_key(args, options)
      when :add_index then add_index(args, options)
      when :create_enum then create_enum(args)
      end
      # Anything else (enable_extension, execute, create_view, ...) is not drawn.
    end

    def create_table(node, args, options)
      name = literal(args.first)
      return warn("create_table without a literal table name", node) unless name.is_a?(String) || name.is_a?(Symbol)

      table = Table.new(name: name.to_s, path: @path, line: node.location.start_line)
      table.comment = literal(options[:comment])
      add_primary_key(table, options)
      statements(node.block).each { |statement| table_statement(table, statement) } if node.block&.body
      @schema.tables[table.name] = table
    end

    def add_primary_key(table, options)
      id = options.key?(:id) ? literal(options[:id]) : :bigint
      primary_key = options.key?(:primary_key) ? literal(options[:primary_key]) : "id"
      return if id == false

      if primary_key.is_a?(Array) # composite: the columns are declared in the block
        table.primary_key = primary_key.map(&:to_s)
        return
      end

      # `id: :uuid`, or `id: { type: :string, limit: 2 }` with column options inline.
      attrs = id.is_a?(Hash) ? id.slice(*COLUMN_OPTIONS).except(:null) : {}
      type = id.is_a?(Hash) ? id.fetch(:type, :bigint) : id
      attrs[:default] = literal(options[:default]) if options.key?(:default)
      table.primary_key = [primary_key.to_s]
      table.columns << Column.new(name: primary_key.to_s, type: type.to_s, null: false, **attrs)
    end

    def table_statement(table, node)
      return unless node.is_a?(Prism::CallNode) && node.receiver

      args, options = Literal.arguments(node)
      case node.name
      when :index then table.indexes << build_index(args.first, options)
      when :references, :belongs_to then add_references(table, args, options)
      when :timestamps then add_timestamps(table, options)
      when :check_constraint then table.checks << literal(args.first).to_s
      when :virtual then add_column(table, node, args.first, literal(options[:type]), options)
      when :column then add_column(table, node, args.first, literal(args[1]), options)
      when *TABLE_IGNORED then nil
      else
        return warn("unrecognized `#{node.name}` in create_table \"#{table.name}\"", node) if args.empty?

        add_column(table, node, args.first, node.name, options)
      end
    end

    def add_column(table, node, name_node, type, options)
      name = literal(name_node)
      return warn("column without a literal name in \"#{table.name}\"", node) unless name.is_a?(String) || name.is_a?(Symbol)

      attrs = COLUMN_OPTIONS.filter_map { |key| [key, literal(options[key])] if options.key?(key) }.to_h
      column = Column.new(name: name.to_s, type: type.to_s, **attrs)
      column.null = true if column.null.nil?
      column.generated = generated(options) if options.key?(:as)
      if type.to_s == "enum" && options.key?(:enum_type)
        column.type = literal(options[:enum_type]).to_s
        @pending_enums << [column, column.type]
      end
      table.primary_key << column.name if literal(options[:primary_key]) == true
      table.columns << column
    end

    def generated(options)
      expression = literal(options[:as]).to_s
      literal(options[:stored]) == true ? "#{expression} (stored)" : expression
    end

    def add_references(table, args, options)
      null = options.key?(:null) ? literal(options[:null]) : true
      type = options.key?(:type) ? literal(options[:type]).to_s : "bigint"
      polymorphic = literal(options[:polymorphic])
      args.each do |arg|
        name = literal(arg).to_s
        columns = ["#{name}_id"]
        if polymorphic
          table.columns << Column.new(name: "#{name}_type", type: "string", null: null)
          columns.unshift("#{name}_type")
        end
        table.columns << Column.new(name: "#{name}_id", type: type, null: null)
        table.indexes << Index.new(columns: columns) unless literal(options[:index]) == false
        add_reference_fk(table, name, literal(options[:foreign_key])) unless polymorphic
      end
    end

    def add_reference_fk(table, name, foreign_key)
      return unless foreign_key

      to_table = foreign_key.is_a?(Hash) && foreign_key[:to_table] ? foreign_key[:to_table].to_s : @inflector.pluralize(name)
      @schema.foreign_keys << ForeignKey.new(from_table: table.name, from_column: "#{name}_id", to_table: to_table, to_column: "id")
    end

    def add_timestamps(table, options)
      null = options.key?(:null) ? literal(options[:null]) : false
      %w[created_at updated_at].each { |name| table.columns << Column.new(name: name, type: "datetime", null: null) }
    end

    def add_foreign_key(args, options)
      from, to = args.map { |node| literal(node).to_s }
      column = options.key?(:column) ? literal(options[:column]).to_s : "#{@inflector.singularize(to)}_id"
      primary_key = options.key?(:primary_key) ? literal(options[:primary_key]).to_s : "id"
      @schema.foreign_keys << ForeignKey.new(from_table: from, from_column: column, to_table: to, to_column: primary_key)
    end

    def add_index(args, options)
      table = @schema.tables[literal(args.first).to_s]
      table&.indexes&.<<(build_index(args[1], options))
    end

    # Arrays and symbols name columns; a string is a column only if it looks like an identifier.
    def build_index(target, options)
      value = literal(target)
      columns, expression = case value
                            when Array then [value.map(&:to_s), nil]
                            when Symbol then [[value.to_s], nil]
                            when /\A\w+\z/ then [[value], nil]
                            else [[], value.to_s]
                            end
      Index.new(columns: columns, expression: expression, unique: literal(options[:unique]) == true,
                where: options.key?(:where) ? literal(options[:where]) : nil,
                name: options.key?(:name) ? literal(options[:name]) : nil)
    end

    def create_enum(args)
      name, values = args.map { |node| literal(node) }
      @schema.enums[name.to_s] = Array(values).map(&:to_s)
    end

    # Literal value, or the source text for anything computed (good enough for a diagram).
    def literal(node)
      return nil if node.nil?

      value = Literal.value(node)
      Literal.known?(value) ? value : node.slice
    end

    def warn(message, node)
      @diagnostics << Diagnostic.new(severity: :warning, message: message, path: @path, line: node.location.start_line)
      nil
    end

    def error(message, path, line)
      @diagnostics << Diagnostic.new(severity: :error, message: message, path: path, line: line)
    end
  end
end
