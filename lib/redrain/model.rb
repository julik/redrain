# frozen_string_literal: true

require "time"

module Redrain
  # Base for every response object. Subclasses declare their shape with `field`;
  # the class handles camelCase↔snake_case mapping and type coercion.
  #
  #   class IssuingUser < Redrain::Model
  #     field :id,         :string
  #     field :first_name, :string, api: "firstName"
  #     field :address,    PhysicalAddress
  #   end
  #
  # Unknown keys are never dropped. Rain adding a field must not break a running
  # integration, so anything we don't know about stays reachable through #[] and
  # #raw and survives a round trip through #to_h.
  class Model
    # Declared fields, keyed by Ruby name. Inherited and never mutated in place.
    # @return [Hash{Symbol => Hash}] field metadata: +:name+, +:api+, +:type+, +:enum+
    def self.fields = @fields ||= superclass.respond_to?(:fields) ? superclass.fields.dup : {}

    # Declares a field and defines its reader.
    #
    # @param name [Symbol] snake_case Ruby name
    # @param type [Symbol, Class<Redrain::Model>, Array] +:string+, +:integer+,
    #   +:number+, +:boolean+, +:time+, +:object+, a Model subclass, or a
    #   one-element Array of any of those for collections
    # @param api [String, nil] wire name, when it differs from +name+
    # @param enum [Array<String>, nil] documented allowed values; not enforced
    # @return [void]
    def self.field(name, type, api: nil, enum: nil)
      api_name = api || name.to_s
      field = { name: name, api: api_name, type: type, enum: enum }
      fields[name] = field
      # Indexed by wire name too: the readers look fields up that way, and a
      # linear scan per attribute is real cost when paging thousands of records.
      by_api_name[api_name] = field
      define_method(name) { self[api_name] }
    end

    # @return [Hash{String => Hash}] the same field metadata, keyed by wire name
    def self.by_api_name = @by_api_name ||= superclass.respond_to?(:by_api_name) ? superclass.by_api_name.dup : {}

    # @param data [Hash, nil] a parsed JSON body
    # @return [Redrain::Model, nil] nil when +data+ is nil
    def self.from_api(data)
      return nil if data.nil?

      new(data)
    end

    # Coerces a raw JSON value into +type+. Public because the resource layer
    # needs it for bare arrays and scalars that never got a Model of their own.
    #
    # @param value [Object] the raw JSON value
    # @param type [Symbol, Class<Redrain::Model>, Array] see {field}
    # @return [Object] the coerced value, or the original if it couldn't be coerced
    def self.cast(value, type)
      return nil if value.nil?

      if type.is_a?(Array)
        return nil unless value.is_a?(Array)

        return value.map { |v| cast(v, type.first) }
      end

      return type.from_api(value) if type.is_a?(Class) && type <= Model

      case type
      when :string  then value.to_s
      when :integer then Integer(value, exception: false) || value
      when :number  then Float(value, exception: false) || value
      when :boolean then coerce_boolean(value)
      when :time    then coerce_time(value)
      else value
      end
    end

    def self.coerce_boolean(value)
      case value
      when true, "true", 1, "1"   then true
      when false, "false", 0, "0" then false
      else value
      end
    end

    def self.coerce_time(value)
      return value if value.is_a?(Time)

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      # Rain occasionally hands back epoch millis where the spec says date-time.
      value.is_a?(Numeric) ? Time.at(value / 1000.0) : value
    end

    private_class_method :coerce_boolean, :coerce_time

    # Reserved key holding a payload that wasn't the object the spec promised.
    UNEXPECTED_KEY = "_unexpected"

    def initialize(data = {})
      # A non-Hash where the spec promised an object is Rain misbehaving, but
      # discarding it would leave no trace at all. Park it under a reserved key
      # so it stays reachable through #raw.
      @raw = case data
      when Hash then data.transform_keys(&:to_s)
      when nil  then {}
      else { UNEXPECTED_KEY => data }
      end.freeze
      @casted = {}
    end

    # @return [Hash] the response body exactly as Rain sent it, string-keyed and
    #   frozen. Use {#to_h} for a copy you can modify.
    attr_reader :raw

    # Reads by wire name (+"firstName"+) or Ruby name (+:first_name+), coercing
    # declared fields and passing unknown ones through untouched.
    #
    # @param key [String, Symbol]
    # @return [Object, nil]
    def [](key)
      key = key.to_s
      field = self.class.by_api_name[key] || self.class.fields[key.to_sym]
      return @raw[key] unless field

      @casted.fetch(field[:api]) do
        @casted[field[:api]] = self.class.cast(@raw[field[:api]], field[:type])
      end
    end

    # True when Rain actually sent the key, which is not the same as it being
    # non-nil — the API distinguishes "absent" from "explicitly null".
    #
    # @param key [String, Symbol]
    # @return [Boolean]
    def key?(key)
      key = key.to_s
      field = self.class.by_api_name[key] || self.class.fields[key.to_sym]
      @raw.key?(field ? field[:api] : key)
    end

    # Wire format, ready to hand back to Rain. Unknown keys included.
    #
    # @return [Hash] a copy — {#raw} is frozen, and handing out the model's own
    #   hash would let a caller mutate it out of step with the cast values
    def to_h = @raw.dup

    # Ruby-side view: snake_case keys, coerced values, unknown keys kept as-is.
    # @return [Hash]
    def to_snake_h
      known = self.class.fields.values.to_h { |f| [f[:name], self[f[:api]]] }
      known.merge(@raw.reject { |k, _| self.class.by_api_name.key?(k) })
    end

    # By class and payload. Deliberately not is_a?, which would make a parent
    # and its subclass disagree about equality depending on the receiver.
    #
    # @param other [Object]
    # @return [Boolean]
    def ==(other) = other.class == self.class && other.raw == @raw
    alias eql? ==

    # @return [Integer]
    def hash = [self.class, @raw].hash

    # @return [String] only the keys Rain actually sent
    def inspect
      pairs = self.class.fields.each_value.filter_map do |f|
        next unless @raw.key?(f[:api])

        "#{f[:name]}=#{self[f[:api]].inspect}"
      end
      "#<#{self.class.name} #{pairs.join(" ")}>"
    end
  end
end
