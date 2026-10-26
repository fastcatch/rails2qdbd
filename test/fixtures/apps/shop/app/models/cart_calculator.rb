# Not a model: plain Ruby living in app/models.
class CartCalculator
  def initialize(items) = @items = items
  def total = @items.sum(&:price)
end
