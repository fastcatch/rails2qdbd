# frozen_string_literal: true

require "test_helper"

class LiteralTest < Minitest::Test
  def call(source) = Prism.parse(source).value.statements.body.first

  def plain_arguments(node)
    args, options = Rails2qdbd::Literal.arguments(node)
    [args.map { |arg| Rails2qdbd::Literal.value(arg) }, options.transform_values { |value| Rails2qdbd::Literal.value(value) }]
  end

  def test_arguments_leave_the_node_intact
    node = call("foo 1, a: 2")

    assert_equal [[1], { a: 2 }], plain_arguments(node)
    assert_equal [[1], { a: 2 }], plain_arguments(node)
  end

  def test_module_can_be_a_hash_key
    assert_equal 1, { Rails2qdbd::Literal => 1 }[Rails2qdbd::Literal]
    assert_equal({ a: 1, "b c": [true] }, Rails2qdbd::Literal.value(call('{ a: 1, "b c" => [true] }')))
  end
end
