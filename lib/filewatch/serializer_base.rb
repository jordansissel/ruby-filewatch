require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SerializerBase
    def serialize(db)
      raise SubclassMustImplement.new("method #serialize not defined in subclass")
    end

    def deserialize(db)
      raise SubclassMustImplement.new("method #deserialize not defined in subclass")
    end

    def serialize_record(k, v)
      raise SubclassMustImplement.new("method #serialize_record not defined in subclass")
    end

    def deserialize_record(record)
      raise SubclassMustImplement.new("method #deserialize_record not defined in subclass")
    end
  end
end
