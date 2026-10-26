# frozen_string_literal: true

require "pathname"

module Rails2qdbd
  # Runs the whole pipeline for one app: inflections -> schema -> models -> resolver -> writer.
  class Converter
    # files: { "name.txt" => text }; tables/relationships: counts for the CLI summary.
    Result = Struct.new(:files, :diagnostics, :tables, :relationships, keyword_init: true)

    SINGLE_FILE = "schema.txt"

    def initialize(config)
      @config = config
      @root = config.app_root
      @grouping = Grouping.new(config)
    end

    def run
      @diagnostics = []
      inflector = load_inflector
      parser = SchemaParser.new(inflector: inflector)
      schemas = @config.schemas.map { |path| relative(path) }
      schema = parser.parse_files(schemas, root: @root)
      @diagnostics.concat(parser.diagnostics)
      models = scan_models
      resolver = Resolver.new(schema, models || {}, inflector: inflector, excluded: ->(table) { @grouping.excluded?(table) })
      resolution = resolver.resolve
      @diagnostics.concat(resolution.diagnostics)

      tables = schema.tables.values.reject { |table| @grouping.excluded?(table.name) }.sort_by(&:name)
      inputs = schemas + (models ? [relative(@config.models)] : [])
      Result.new(files: render(tables, resolution, inputs), diagnostics: @diagnostics, tables: tables.size,
                 relationships: resolution.relationships.size)
    end

    private

    def load_inflector
      inflector = Inflector.new
      path = @config.inflections
      if path && File.file?(full = File.expand_path(path, @root))
        @diagnostics.concat(inflector.apply_file(File.read(full), path: path))
      end
      inflector
    end

    # nil when model scanning is off or there is no models directory.
    def scan_models
      return nil unless @config.models

      dir = File.expand_path(@config.models, @root)
      unless File.directory?(dir)
        @diagnostics << Catalog::Diagnostic.new(
          message: "models directory not found: #{@config.models} (relationships come from the schema only)",
        )
        return nil
      end

      sources = Dir.glob("**/*.rb", base: dir).sort.to_h do |file|
        [File.join(relative(@config.models), file), File.read(File.join(dir, file))]
      end
      scanner = ModelScanner.new
      scanner.scan(sources: sources).tap { @diagnostics.concat(scanner.diagnostics) }
    end

    # Paths inside the app are shown relative to it, so output does not depend on the cwd.
    def relative(path)
      full = Pathname(File.expand_path(path, @root))
      inside = full.relative_path_from(Pathname(File.expand_path(@root))).to_s
      inside.start_with?("..") ? path : inside
    end

    def render(tables, resolution, inputs)
      writer = Writer.new
      by_file = tables.group_by { |table| file_for(table) }
      # No tables still gives a headed file, so the output exists and --check has something to compare.
      by_file = { SINGLE_FILE => [] } if by_file.empty?
      by_file.sort.to_h do |file, file_tables|
        texts = file_tables.map do |table|
          writer.render_table(table, relationships: resolution.relationships,
                                     table_notes: resolution.table_notes.fetch(table.name, []),
                                     column_notes: resolution.column_notes.fetch(table.name, {}))
        end
        [file, writer.render_file(tables_text: texts, inputs: inputs)]
      end
    end

    # One file per group only when groups are configured and the output is a directory.
    def file_for(table)
      output = @config.output
      split = @config.groups.any? && output && !output.end_with?(".txt")
      split ? "#{@grouping.group_for(table.name)}.txt" : SINGLE_FILE
    end
  end
end
