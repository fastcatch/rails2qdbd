# frozen_string_literal: true

require_relative "rails2qdbd/version"
require_relative "rails2qdbd/catalog"
require_relative "rails2qdbd/literal"
require_relative "rails2qdbd/inflector"
require_relative "rails2qdbd/schema_parser"
require_relative "rails2qdbd/model_scanner"
require_relative "rails2qdbd/resolver"
require_relative "rails2qdbd/writer"
require_relative "rails2qdbd/config"
require_relative "rails2qdbd/grouping"
require_relative "rails2qdbd/converter"
require_relative "rails2qdbd/output"
require_relative "rails2qdbd/cli"

# Converts a Rails project's db/schema.rb and app/models into qdbd schema files.
# Pipeline (see Converter): SchemaParser + ModelScanner -> Resolver -> Writer -> Output.
module Rails2qdbd
  class Error < StandardError; end

  # Converts the app at app_root. overrides: Config keys (output:, models:, exclude:, ...).
  def self.convert(app_root, config_path: nil, **overrides)
    Converter.new(Config.load(app_root, path: config_path, overrides: overrides)).run
  end
end
