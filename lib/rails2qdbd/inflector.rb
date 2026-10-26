# frozen_string_literal: true

require "prism"
require "active_support/inflector"

module Rails2qdbd
  # ActiveSupport's inflector over a private copy of the English rules, so a project's own
  # inflections apply to this conversion only and the global inflector is never mutated.
  class Inflector
    include ActiveSupport::Inflector

    RULES = %i[irregular plural singular uncountable acronym].freeze

    def initialize
      english = ActiveSupport::Inflector.inflections(:en)
      @inflections = english.dup
      # Inflections#dup shares the uncountables' word list with the original; rebuild it so
      # `uncountable` here cannot leak into the global inflector.
      @inflections.clear(:uncountables)
      @inflections.uncountable(english.uncountables.to_a)
    end

    # Every ActiveSupport::Inflector method looks its rules up through here.
    def inflections(_locale = :en)
      block_given? ? yield(@inflections) : @inflections
    end

    # Rails table names come from the demodulized class name (Admin::User -> users).
    def tableize(class_name) = pluralize(underscore(demodulize(class_name.to_s)))

    # Applies the literal inflection rules of config/initializers/inflections.rb without
    # executing it. Returns warnings for everything it skipped.
    def apply_file(source, path:)
      diagnostics = []
      result = Prism.parse(source)
      return [Catalog::Diagnostic.new(severity: :warning, message: "syntax error, inflections ignored", path: path)] if result.failure?

      each_call(result.value) do |call|
        next unless call.receiver.is_a?(Prism::LocalVariableReadNode)

        message = apply_rule(call)
        diagnostics << Catalog::Diagnostic.new(message: message, path: path, line: call.location.start_line) if message
      end
      diagnostics
    end

    private

    # nil when applied, else the reason it was skipped.
    def apply_rule(call)
      return "inflection `#{call.name}` ignored" unless RULES.include?(call.name)

      args = (call.arguments&.arguments || []).map { |node| Literal.value(node) }
      return "inflection `#{call.name}` with non-literal arguments ignored" unless args.all? { |arg| Literal.known?(arg) }

      @inflections.public_send(call.name, *args)
      nil
    end

    def each_call(node, &block)
      yield node if node.is_a?(Prism::CallNode)
      node.compact_child_nodes.each { |child| each_call(child, &block) }
    end
  end
end
