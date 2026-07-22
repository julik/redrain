# frozen_string_literal: true

module Generator
  module Naming
    module_function

    # "firstName" -> "first_name", "encryptedPAN" -> "encrypted_pan"
    def snake(name)
      name.to_s
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .tr("-", "_")
          .downcase
    end

    # "first_name" / "firstName" -> "FirstName"
    def pascal(name) = snake(name).split("_").map(&:capitalize).join

    # Only has to cover the resource names Rain actually uses.
    def singular(word)
      case word
      when /ies\z/         then "#{word[0..-4]}y"
      when /(ss|us|nce)\z/ then word
      when /s\z/           then word[0..-2]
      else word
      end
    end

    # Stainless's rule for naming an inline response schema, reproduced so our
    # types line up with the Python SDK's: singular leaf resource + method.
    def response_class(resource_leaf, method) = "#{pascal(singular(resource_leaf))}#{pascal(method)}Response"

    YARD_PRIMITIVES = {
      ":string"  => "String",
      ":integer" => "Integer",
      ":number"  => "Float",
      ":boolean" => "Boolean",
      ":time"    => "Time",
      ":object"  => "Hash"
    }.freeze

    # Turns a generated type expression ("[IssuingCard]", ":time", "Spend") into
    # the name YARD uses in @param/@return tags.
    def yard_type(expression)
      expression = expression.to_s
      return "Array<#{yard_type(expression[1..-2])}>" if expression.start_with?("[")
      return YARD_PRIMITIVES.fetch(expression) if expression.start_with?(":")

      "Redrain::#{expression}"
    end

    # Ruby reserved words that would blow up as method or parameter names.
    RESERVED = %w[
      alias and begin break case class def defined do else elsif end ensure false
      for if in module next nil not or redo rescue retry return self super then
      true undef unless until when while yield method hash class send
    ].freeze

    def safe_param(name)
      name = snake(name)
      RESERVED.include?(name) ? "#{name}_" : name
    end
  end
end
