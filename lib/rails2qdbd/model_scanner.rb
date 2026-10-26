# frozen_string_literal: true

require "prism"

module Rails2qdbd
  # Reads model files statically into Catalog::Models: associations,
  # enums, attachments, table overrides, abstract classes, STI parents and concerns.
  class ModelScanner
    include Catalog

    ASSOCIATIONS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze
    ASSOCIATION_OPTIONS = %i[class_name foreign_key primary_key polymorphic as through join_table
                           association_foreign_key foreign_type].freeze
    ATTACHMENTS = { has_one_attached: :one, has_many_attached: :many }.freeze
    ENUM_OPTIONS = %i[prefix suffix scopes default instance_methods validate].freeze
    ROOTS = %w[ActiveRecord::Base].freeze
    # Assumed abstract when the project has no file for it.
    IMPLICIT_ABSTRACT = %w[ApplicationRecord].freeze

    # One class or concern as written, before deciding whether it is a model.
    Unit = Struct.new(:model, :scopes, :warnings, :concern, keyword_init: true)

    attr_reader :diagnostics

    def initialize
      @diagnostics = []
    end

    # sources: { relative_path => source }. Returns { "Admin::User" => Model } for models only.
    def scan(sources:)
      @units = {}
      sources.sort.each { |path, source| scan_file(path, source) }
      models = @units.values.reject(&:concern).select { |unit| model?(unit.model.name) }
      models.sort_by { |unit| unit.model.name }.to_h do |unit|
        apply_concerns(unit)
        # A concern's warnings arrive with every class that includes it; report them once.
        @diagnostics.concat(unit.warnings.uniq - @diagnostics)
        [unit.model.name, unit.model]
      end
    end

    private

    def scan_file(path, source)
      @path = path
      result = Prism.parse(source)
      return @diagnostics << Diagnostic.new(message: "syntax error, file skipped", path: path) if result.failure?

      visit_scope(result.value.statements.body, [])
    end

    # scopes: full names of the enclosing modules/classes, outermost first.
    def visit_scope(statements, scopes)
      statements.each do |node|
        case node
        when Prism::ModuleNode then visit_module(node, scopes)
        when Prism::ClassNode then visit_class(node, scopes)
        end
      end
    end

    def visit_module(node, scopes)
      name = qualified(Literal.constant_name(node.constant_path), scopes)
      body = node.body&.body || []
      included = body.find { |n| n.is_a?(Prism::CallNode) && n.name == :included && n.receiver.nil? && n.block }
      if included || body.any? { |n| concern_extension?(n) }
        unit = unit_for(name, scopes + [name], concern: true)
        collect(included.block.body&.body || [], unit) if included
        body.each { |n| add_include(n, unit) }
      end
      visit_scope(body, scopes + [name])
    end

    def visit_class(node, scopes)
      name = qualified(Literal.constant_name(node.constant_path), scopes)
      unit = unit_for(name, scopes + [name], concern: false)
      unit.model.superclass ||= Literal.constant_name(node.superclass)
      unit.model.path ||= @path
      unit.model.line ||= node.location.start_line
      collect(node.body&.body || [], unit)
      visit_scope(node.body&.body || [], scopes + [name])
    end

    # `extend ActiveSupport::Concern`: the module's includes reach the class, even without `included do`.
    def concern_extension?(node)
      node.is_a?(Prism::CallNode) && node.name == :extend && node.receiver.nil? &&
        node.arguments&.arguments&.any? { |arg| Literal.constant_name(arg) == "ActiveSupport::Concern" }
    end

    def unit_for(name, scopes, concern:)
      @units[name] ||= Unit.new(model: Model.new(name: name), scopes: scopes, warnings: [], concern: concern)
    end

    def qualified(name, scopes) = scopes.empty? ? name : "#{scopes.last}::#{name}"

    # Class-body declarations; `inherited` lets with_options pass its options down.
    def collect(statements, unit, inherited = {})
      statements.each do |node|
        next unless node.is_a?(Prism::CallNode)

        if node.receiver.is_a?(Prism::SelfNode) then self_assignment(node, unit.model)
        elsif node.receiver.nil? || node.receiver.is_a?(Prism::LocalVariableReadNode)
          declaration(node, unit, inherited)
        end
      end
    end

    def self_assignment(node, model)
      value = Literal.value(node.arguments&.arguments&.first)
      return unless Literal.known?(value)

      case node.name
      when :table_name= then model.table_name = value.to_s
      when :primary_key= then model.primary_key = value.is_a?(Array) ? value.map(&:to_s) : value.to_s
      when :abstract_class= then model.abstract = value == true
      end
    end

    def declaration(node, unit, inherited)
      case node.name
      when *ASSOCIATIONS then association(node, unit, inherited)
      when *ATTACHMENTS.keys then attachment(node, unit.model)
      when :enum then enum(node, unit)
      when :include then add_include(node, unit)
      when :primary_abstract_class then unit.model.abstract = true
      when :with_options then with_options(node, unit, inherited)
      end
    end

    def association(node, unit, inherited)
      args, options = Literal.arguments(node)
      name = Literal.value(args.first)
      return unless name.is_a?(Symbol) || name.is_a?(String)

      values = inherited.dup
      options.slice(*ASSOCIATION_OPTIONS).each do |key, value_node|
        value = Literal.value(value_node)
        unless Literal.known?(value)
          return skip(unit, node, "#{unit.model.name} #{node.name} :#{name}: non-literal #{key}, skipped")
        end

        values[key] = value
      end
      values = values.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
      unit.model.associations << Association.new(macro: node.name, name: name.to_s, options: values,
                                                 path: @path, line: node.location.start_line)
    end

    def with_options(node, unit, inherited)
      return unless node.block

      _, options = Literal.arguments(node)
      values = options.slice(*ASSOCIATION_OPTIONS).transform_values { |v| Literal.value(v) }
      return skip(unit, node, "#{unit.model.name} with_options: non-literal options, skipped") unless values.values.all? { |v| Literal.known?(v) }

      collect(node.block.body&.body || [], unit, inherited.merge(values))
    end

    def attachment(node, model)
      name = Literal.value(node.arguments&.arguments&.first)
      model.attachments << [name.to_s, ATTACHMENTS.fetch(node.name)] if name.is_a?(Symbol) || name.is_a?(String)
    end

    # enum :status, {...} | enum :status, [...] | enum :status, a: 0, b: 1 | enum status: {...}, _prefix: true
    def enum(node, unit)
      args, options = Literal.arguments(node)
      values = options.reject { |key, _| key.start_with?("_") || ENUM_OPTIONS.include?(key) }
      pairs = if args.any?
                [[Literal.value(args[0]), args[1] ? Literal.value(args[1]) : keyword_values(values)]]
              else
                values.map { |key, value| [key, Literal.value(value)] }
              end
      pairs.each do |name, values|
        next skip(unit, node, "#{unit.model.name} enum :#{name}: non-literal values, skipped") unless values.is_a?(Hash) || values.is_a?(Array)

        unit.model.enums[name.to_s] = enum_labels(values)
      end
    end

    # The values of `enum :status, a: 0, b: 1`, or UNKNOWN when there are none or one is not a literal.
    def keyword_values(nodes)
      values = nodes.transform_values { |node| Literal.value(node) }
      values.any? && values.values.all? { |value| Literal.known?(value) } ? values : Literal::UNKNOWN
    end

    def enum_labels(values)
      return values.map(&:to_s) if values.is_a?(Array)

      values.map { |key, value| key.to_s == value.to_s ? key.to_s : "#{key} (#{value})" }
    end

    def add_include(node, unit)
      return unless node.is_a?(Prism::CallNode) && node.name == :include && node.receiver.nil?

      (node.arguments&.arguments || []).each do |arg|
        name = Literal.constant_name(arg)
        unit.model.includes << name if name
      end
    end

    def skip(unit, node, message)
      unit.warnings << Diagnostic.new(message: message, path: @path, line: node.location.start_line)
      nil
    end

    # Constant lookup like Ruby's lexical scope: innermost scope first, then top level.
    def resolve(name, scopes)
      return nil unless name

      name = name.delete_prefix("::")
      scopes.reverse.map { |scope| "#{scope}::#{name}" }.find { |candidate| @units.key?(candidate) } ||
        (@units.key?(name) ? name : nil)
    end

    def model?(name, seen = [])
      unit = @units[name]
      return false if unit.nil? || unit.concern || seen.include?(name)

      superclass = unit.model.superclass
      return false unless superclass

      resolved = resolve(superclass, unit.scopes[0...-1])
      unit.model.superclass = resolved || superclass
      return model?(resolved, seen + [name]) if resolved

      ROOTS.include?(superclass.delete_prefix("::")) || IMPLICIT_ABSTRACT.include?(superclass)
    end

    # A concern's `included do` declarations (and the concerns it includes) land on the class.
    def apply_concerns(unit, seen = [])
      model = unit.model
      unit.model.includes.each do |name|
        concern = @units[resolve(name, unit.scopes)]
        next unless concern&.concern && !seen.include?(concern.model.name)

        # Expanded on a copy, so the next class including this concern starts from it as written.
        concern = copy(concern)
        apply_concerns(concern, seen + [concern.model.name])
        model.associations.unshift(*concern.model.associations)
        model.attachments.unshift(*concern.model.attachments)
        model.enums.merge!(concern.model.enums) { |_key, own, _theirs| own }
        unit.warnings.concat(concern.warnings)
      end
    end

    def copy(unit)
      model = unit.model.dup
      model.associations = model.associations.dup
      model.attachments = model.attachments.dup
      model.enums = model.enums.dup
      unit.dup.tap { |u| u.model = model; u.warnings = u.warnings.dup }
    end
  end
end
