# frozen_string_literal: true

module Rails2qdbd
  # Derives relationships and documentation notes from the schema and the models.
  # Database foreign keys come first and win every conflict.
  class Resolver
    include Catalog

    MODEL_NOTE = "relationship from model association (no database constraint)"

    # relationships: { [from_table, from_column] => Relationship }
    # table_notes: { table => [String] }; column_notes: { table => { column => [String] } }
    Resolution = Struct.new(:relationships, :table_notes, :column_notes, :diagnostics, keyword_init: true)

    # excluded: tables left out of the output; relationships into them become notes.
    def initialize(schema, models, inflector:, excluded: ->(_table) { false })
      @schema = schema
      @models = models
      @inflector = inflector
      @excluded = excluded
    end

    def resolve
      @relationships = {}
      @hints = Hash.new { |hash, key| hash[key] = [] } # [table, column] => [:has_one | :has_many]
      @polymorphic = {} # [table, column] => { type:, targets: [] }
      @table_notes = Hash.new { |hash, key| hash[key] = [] }
      @column_notes = Hash.new { |hash, table| hash[table] = Hash.new { |h, column| h[column] = [] } }
      @attachments = Hash.new { |hash, key| hash[key] = [] } # table => [[name, :one | :many]]
      @diagnostics = []
      # The model owning each table (first by name), for association targets.
      @table_models = @models.values.reject { |model| model.abstract || sti_child?(model) }
                             .each_with_object({}) { |model, index| index[table_for(model)] ||= model }

      @schema.foreign_keys.each { |fk| add_database_fk(fk) }
      @models.each_value { |model| resolve_model(model) unless model.abstract }
      finish
    end

    # The table a model reads: STI subclasses use their base class's table.
    def table_for(model)
      return nil if model.abstract

      return table_for(@models[model.superclass]) if sti_child?(model)

      model.table_name || @inflector.tableize(model.name)
    end

    private

    # A subclass of a concrete model shares its table (single-table inheritance).
    def sti_child?(model) = !!@models[model.superclass]&.then { |parent| !parent.abstract }

    def add_database_fk(fk)
      label = "foreign key #{fk.from_table}.#{fk.from_column} -> #{fk.to_table}.#{fk.to_column}"
      problem = missing(fk.from_table, fk.from_column) || missing(fk.to_table, fk.to_column)
      return @diagnostics << Diagnostic.new(message: "#{label}: #{problem}, skipped") if problem

      @relationships[[fk.from_table, fk.from_column]] ||= Relationship.new(
        from_table: fk.from_table, from_column: fk.from_column, to_table: fk.to_table, to_column: fk.to_column, source: :database,
      )
    end

    # Declarations of abstract parents apply to each subclass, resolved as the subclass's own.
    def resolve_model(model)
      table = table_for(model)
      declared = [*abstract_ancestors(model), model]
      declared.flat_map(&:associations).each { |association| resolve_association(model, table, association) }
      return unless @schema.tables.key?(table)

      declared.map(&:enums).reduce(:merge).each do |column, values|
        next if (schema_column = @schema.tables[table].column(column)).nil? || schema_column.enum_values

        @column_notes[table][column] << "enum: #{values.join(', ')}"
      end
      attachments = declared.flat_map(&:attachments)
      @attachments[table].concat(attachments)
      active_storage_target(model) if attachments.any?
    end

    # Abstract superclasses, outermost first. An STI child stops at its concrete parent, whose own
    # declarations are resolved with it.
    def abstract_ancestors(model)
      chain = []
      while (parent = @models[model.superclass]) && parent.abstract && !chain.include?(parent)
        chain.unshift(parent)
        model = parent
      end
      chain
    end

    # Active Storage's own models live in Rails, so its polymorphic record is described from
    # the app side: every model with has_one_attached / has_many_attached is a target.
    def active_storage_target(model)
      key = %w[active_storage_attachments record_id]
      return unless @schema.tables[key.first]&.column(key.last)

      entry = (@polymorphic[key] ||= { type: "record_type", targets: [] })
      entry[:targets] |= [model.name]
    end

    def resolve_association(model, table, association)
      context = [model, association]
      return warn(context, "table #{table} not found") unless @schema.tables.key?(table)

      case association.macro
      when :belongs_to then belongs_to(context, table)
      when :has_many, :has_one then has_many(context, table)
      when :has_and_belongs_to_many then habtm(context, table)
      end
    end

    def belongs_to(context, table)
      _, association = context
      options = association.options
      column = options[:foreign_key] || "#{association.name}_id"
      return polymorphic_belongs_to(table, column, options[:foreign_type] || "#{association.name}_type") if options[:polymorphic]

      target = target_table(context, options[:class_name] || @inflector.camelize(association.name)) or return
      add_model_edge(context, table, column, target, options[:primary_key] || primary_key(target, model_for_table(target)))
    end

    def has_many(context, table)
      model, association = context
      options = association.options
      return if options[:through]
      return polymorphic_target(context) if options[:as]

      default_class = association.macro == :has_many ? @inflector.singularize(association.name) : association.name
      target = target_table(context, options[:class_name] || @inflector.camelize(default_class)) or return
      column = options[:foreign_key] || @inflector.foreign_key(model.name)
      @hints[[target, column]] << association.macro if add_model_edge(context, target, column, table,
                                                                      options[:primary_key] || primary_key(table, model))
    end

    def habtm(context, table)
      model, association = context
      options = association.options
      target = target_table(context, options[:class_name] || @inflector.camelize(@inflector.singularize(association.name))) or return
      join = options[:join_table] || [table, target].sort.join("\0").gsub(/^(.*_)(.+)\0\1(.+)/, '\1\2_\3').tr("\0", "_")
      return warn(context, "join table #{join} not found") unless @schema.tables.key?(join)

      add_model_edge(context, join, options[:foreign_key] || @inflector.foreign_key(model.name), table, primary_key(table, model))
      target_class = options[:class_name] || @inflector.camelize(@inflector.singularize(association.name))
      add_model_edge(context, join, options[:association_foreign_key] || @inflector.foreign_key(target_class),
                     target, primary_key(target, model_for_table(target)))
    end

    def polymorphic_belongs_to(table, column, type_column)
      return unless @schema.tables[table].column(column)

      @polymorphic[[table, column]] ||= { type: type_column, targets: [] }
    end

    # has_many :comments, as: :commentable -> Model is one of comments.commentable_id's targets.
    def polymorphic_target(context)
      model, association = context
      options = association.options
      target = target_table(context, options[:class_name] || @inflector.camelize(@inflector.singularize(association.name))) or return
      key = [target, options[:foreign_key] || "#{options[:as]}_id"]
      problem = missing(*key)
      return warn(context, problem) if problem

      entry = (@polymorphic[key] ||= { type: options[:foreign_type] || "#{options[:as]}_type", targets: [] })
      entry[:targets] |= [model.name]
    end

    # Rails-like class lookup (namespace first), else a table named after the class.
    def target_table(context, class_name)
      model, = context
      scopes = model.name.split("::")[0...-1]
      candidates = scopes.size.downto(0).map { |n| [*scopes.first(n), class_name.delete_prefix("::")].join("::") }
      found = candidates.filter_map { |name| @models[name] }.first
      table = found ? table_for(found) : @inflector.tableize(class_name)
      return table if @schema.tables.key?(table)

      warn(context, found ? "table #{table} not found" : "class #{class_name} not found")
    end

    def model_for_table(table) = @table_models[table]

    # A composite key cannot be an association target, so only a single-column key counts.
    def primary_key(table, model)
      return model.primary_key if model&.primary_key.is_a?(String)

      @schema.tables[table].primary_key.then { |pk| pk.size == 1 ? pk.first : "id" }
    end

    # true when the edge exists (new or already known with the same target).
    def add_model_edge(context, from_table, from_column, to_table, to_column)
      problem = missing(from_table, from_column) || missing(to_table, to_column)
      return warn(context, problem) && false if problem

      key = [from_table, from_column]
      existing = @relationships[key]
      if existing && [existing.to_table, existing.to_column] != [to_table, to_column]
        source = existing.source == :database ? "the database foreign key" : "another association"
        winner = existing.source == :database ? "the database" : "the first"
        return warn(context, "points to #{to_table}.#{to_column} but #{source} points to " \
                             "#{existing.to_table}.#{existing.to_column}; using #{winner}", skipped: false) && false
      end

      @relationships[key] ||= Relationship.new(from_table: from_table, from_column: from_column, to_table: to_table,
                                               to_column: to_column, source: :model)
      true
    end

    def missing(table, column)
      return "table #{table} not found" unless @schema.tables.key?(table)

      "column #{table}.#{column} not found" unless @schema.tables[table].column(column)
    end

    def warn(context, problem, skipped: true)
      model, association = context
      @diagnostics << Diagnostic.new(message: "#{model.name} #{association.macro} :#{association.name}: #{problem}#{', skipped' if skipped}",
                                     path: association.path, line: association.line)
      nil
    end

    def finish
      drop_excluded
      @relationships.each do |key, relationship|
        relationship.cardinality = :one_to_one if one_to_one?(key)
        @column_notes[key.first][key.last] << MODEL_NOTE if relationship.source == :model
      end
      @polymorphic.sort.each do |(table, column), entry|
        targets = entry[:targets].sort
        @column_notes[table][column] << "polymorphic (type in #{entry[:type]})#{": #{targets.join(', ')}" if targets.any?}"
      end
      sti_notes
      @attachments.each do |table, attachments|
        next if attachments.empty?

        @table_notes[table] << "attachments: #{attachments.uniq.map { |name, kind| "#{name} (#{kind})" }.join(', ')}"
      end
      Resolution.new(relationships: @relationships, table_notes: plain(@table_notes),
                     column_notes: plain(@column_notes).transform_values { |columns| plain(columns) }, diagnostics: @diagnostics)
    end

    def drop_excluded
      @relationships.reject! do |(table, column), relationship|
        next false unless @excluded.call(table) || @excluded.call(relationship.to_table)

        @column_notes[table][column] << "references #{relationship.to_table} (excluded)" unless @excluded.call(table)
        true
      end
    end

    def one_to_one?((table, column))
      unique = @schema.tables[table].indexes.any? { |index| index.single_column? && index.unique && index.columns == [column] }
      hints = @hints[[table, column]]
      unique || (hints.include?(:has_one) && !hints.include?(:has_many))
    end

    def sti_notes
      subclasses = @models.values.select { |model| sti_child?(model) }
      subclasses.group_by { |model| table_for(model) }.sort.each do |table, models|
        @table_notes[table].unshift("STI: #{models.map(&:name).sort.join(', ')}") if @schema.tables.key?(table)
      end
    end

    # Drops the default procs so callers get ordinary hashes.
    def plain(hash) = {}.merge(hash.reject { |_, value| value.empty? })
  end
end
