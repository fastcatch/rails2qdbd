# frozen_string_literal: true

require "optparse"

module Rails2qdbd
  # `rails2qdbd [APP_ROOT] [options]`. Exit codes: 0 ok,
  # 1 errors or out of date (--check), 2 usage error. Paths given here are relative to cwd.
  class CLI
    def initialize(argv, out: $stdout, err: $stderr, cwd: Dir.pwd)
      @argv = argv.dup
      @out = out
      @err = err
      @cwd = cwd
      @overrides = {}
    end

    def run
      parser = option_parser
      args = parser.parse(@argv)
      return 0 if @done

      app_root = File.expand_path(args.first || ".", @cwd)
      config = Config.load(app_root, path: @config_path, overrides: @overrides)
      result = Converter.new(config).run
      report(result.diagnostics)
      return 1 if result.diagnostics.any? { |d| d.severity == :error }

      deliver(result, config)
    rescue OptionParser::ParseError => e
      @err.puts "rails2qdbd: #{e.message}", parser.banner
      2
    rescue Error => e
      @err.puts "rails2qdbd: #{e.message}"
      1
    end

    private

    def option_parser
      OptionParser.new do |o|
        o.banner = "Usage: rails2qdbd [APP_ROOT] [options]"
        o.separator "Converts db/schema.rb and app/models into qdbd schema files (APP_ROOT defaults to .)."
        o.on("-o", "--output PATH", "a .txt file or a directory (default: config, else stdout)") { |v| @overrides[:output] = path(v) }
        o.on("--schema FILE", "schema file, repeatable (default: db/schema.rb)") { |v| (@overrides[:schemas] ||= []) << path(v) }
        o.on("--models DIR", "models directory (default: app/models)") { |v| @overrides[:models] = path(v) }
        o.on("--no-models", "schema only, no model associations") { @overrides[:models] = false }
        o.on("-c", "--config FILE", "config file (default: APP_ROOT/.rails2qdbd.yml)") { |v| @config_path = path(v) }
        o.on("--exclude GLOB", "leave out matching tables, repeatable") { |v| (@overrides[:exclude] ||= []) << v }
        o.on("--check", "write nothing; exit 1 if the output is out of date") { @check = true }
        o.on("-q", "--quiet", "no warnings or summary") { @quiet = true }
        o.on("-v", "--version", "print the version") { finish("rails2qdbd #{VERSION}") }
        o.on("-h", "--help", "print this help") { finish(o.help) }
      end
    end

    def finish(text)
      @out.puts text
      @done = true
    end

    def path(value) = File.expand_path(value, @cwd)

    def report(diagnostics)
      diagnostics.each { |d| @err.puts d.to_s if d.severity == :error || !@quiet }
    end

    def deliver(result, config)
      output = config.output && File.expand_path(config.output, config.app_root)
      return check(result, output) if @check
      unless output
        @out.print(result.files.values.join("\n"))
        return 0
      end

      written = Output.write(result, output)
      unless @quiet
        @out.puts "wrote #{written.size} file(s) to #{output}: #{result.tables} tables, " \
                  "#{result.relationships} relationship#{'s' unless result.relationships == 1}"
      end
      0
    end

    def check(result, output)
      unless output
        @err.puts "rails2qdbd: --check needs an output path (-o, or output: in the config)"
        return 2
      end

      problems = Output.stale(result, output)
      problems.each { |problem| @err.puts "out of date: #{problem}" }
      @out.puts "up to date" if problems.empty?
      problems.empty? ? 0 : 1
    end
  end
end
