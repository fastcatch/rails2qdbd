# frozen_string_literal: true

require "yaml"

module Rails2qdbd
  # Settings from .rails2qdbd.yml (or --config), overridden by command-line options.
  # Paths are relative to the app root.
  class Config
    FILE = ".rails2qdbd.yml"
    DEFAULTS = {
      output: nil,
      schemas: ["db/schema.rb"],
      models: "app/models",
      inflections: "config/initializers/inflections.rb",
      exclude: [],
      default_group: "app",
      groups: {},
    }.freeze

    attr_reader :app_root, :path, *DEFAULTS.keys

    # overrides: same keys as the file; :exclude adds to the file's list instead of replacing it.
    def self.load(app_root, path: nil, overrides: {})
      if path
        raise Error, "config file not found: #{path}" unless File.file?(File.expand_path(path, app_root))
      elsif File.file?(File.join(app_root, FILE))
        path = FILE
      end
      values = path ? read(File.expand_path(path, app_root), path) : {}
      new(app_root, path, values, overrides)
    end

    def self.read(full_path, label)
      data = YAML.safe_load_file(full_path) || {}
      raise Error, "#{label} must be a mapping of settings" unless data.is_a?(Hash)

      data.transform_keys(&:to_sym).tap do |values|
        unknown = values.keys - DEFAULTS.keys
        raise Error, "unknown config key in #{label}: #{unknown.join(', ')}" if unknown.any?
        unless values[:groups].nil? || values[:groups].is_a?(Hash)
          raise Error, "groups in #{label} must map group names to table globs"
        end
      end
    rescue Psych::Exception => e
      raise Error, "#{label}: invalid YAML (#{e.message})"
    end

    def initialize(app_root, path, values, overrides)
      @app_root = app_root
      @path = path
      settings = DEFAULTS.merge(values.compact).merge(overrides.except(:exclude).compact)
      @output = settings[:output]
      @schemas = Array(settings[:schemas]).map(&:to_s)
      @models = settings[:models] == false ? false : settings[:models].to_s
      @inflections = settings[:inflections] == false ? false : settings[:inflections].to_s
      @exclude = (Array(settings[:exclude]) + Array(overrides[:exclude])).map(&:to_s)
      @default_group = settings[:default_group].to_s
      @groups = settings[:groups].to_h { |name, globs| [name.to_s, Array(globs).map(&:to_s)] }
    end
  end
end
