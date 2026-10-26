# frozen_string_literal: true

require "prism"

module Rails2qdbd
  # Turns Prism nodes into plain Ruby values without evaluating anything: project code is never run.
  module Literal
    # Returned for anything that is not a literal (method calls, variables, constants, ...).
    UNKNOWN = Object.new.tap { |o| def o.inspect = "Literal::UNKNOWN" }.freeze

    module_function

    def value(node)
      case node
      when Prism::StringNode, Prism::SymbolNode then node.unescaped
      when Prism::IntegerNode, Prism::FloatNode then node.value
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::ArrayNode then all_known(node.elements.map { |element| value(element) })
      when Prism::HashNode, Prism::KeywordHashNode then hash_value(node)
      when Prism::LambdaNode then lambda_value(node)
      when Prism::RegularExpressionNode then regexp(node)
      else UNKNOWN
      end
    end

    def known?(value) = !value.equal?(UNKNOWN)

    # [positional nodes, { key_symbol => value node }] of a call's arguments.
    def arguments(call)
      nodes = call.arguments&.arguments || []
      keywords = nodes.last if nodes.last.is_a?(Prism::KeywordHashNode)
      nodes = nodes[0...-1] if keywords
      options = {}
      keywords&.elements&.each do |element|
        next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

        options[element.key.unescaped.to_sym] = element.value
      end
      [nodes, options]
    end

    # Full constant name of a ConstantReadNode / ConstantPathNode ("ActiveRecord::Base"), else nil.
    def constant_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = node.parent ? constant_name(node.parent) : ""
        parent && "#{parent}::#{node.name}".delete_prefix("::")
      end
    end

    def hash_value(node)
      node.elements.each_with_object({}) do |element, result|
        return UNKNOWN unless element.is_a?(Prism::AssocNode)

        key = value(element.key)
        val = value(element.value)
        return UNKNOWN unless known?(key) && known?(val)

        result[key.is_a?(String) ? key.to_sym : key] = val
      end
    end

    def regexp(node)
      flags = (node.ignore_case? ? Regexp::IGNORECASE : 0) | (node.extended? ? Regexp::EXTENDED : 0) |
              (node.multi_line? ? Regexp::MULTILINE : 0)
      Regexp.new(node.unescaped, flags)
    end

    def all_known(values) = values.all? { |v| known?(v) } ? values : UNKNOWN

    # Rails dumps SQL defaults as `-> { "now()" }`; the string is the expression.
    def lambda_value(node)
      statements = node.body&.body || []
      statements.size == 1 && statements.first.is_a?(Prism::StringNode) ? statements.first.unescaped : UNKNOWN
    end
  end
end
