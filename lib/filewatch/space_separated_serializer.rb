require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SpaceSeparatedSerializer < SerializerBase

    def serialize(db)
      db.map do |key, value|
        serialize_record(key, value)
      end.join("\n").concat("\n")
    end

    def deserialize(io)
      io.each do |record|
        yield deserialize_record(record)
      end
    end

    def serialize_record(k, v)
      "#{k} #{v}"
    end

    def deserialize_record(record)
      parts = record.split(" ")
      parse_line_v2(parts) || parse_line_v1(parts)
    end

    private

    def parse_line_v2(parts)
      # new fingerprint e.g.
      # 8864371933797704358,0,255 45003 #{Time.now.to_f} 1946650054937152164,37002,255
      # ^fingerprint1 offset^ ^size ^position ^last_seen ^fingerprint2 offset^     ^size
      return false if !parts.first.include?(",")
      first_fingerprint = parts.shift.split(",").map(&:to_i)
      first_fingerprint[0] = Fnv.coerce_bignum(first_fingerprint[0])
      pos = parts.shift.to_i
      exp = Float(parts.shift)
      second_fingerprint = nil
      if !parts.empty?
        fp_array = parts.shift.split(",").map(&:to_i)
        fp_array[0] = Fnv.coerce_bignum(fp_array[0])
        second_fingerprint = FingerprintStruct.new(*fp_array)
      end
      [FingerprintStruct.new(*first_fingerprint), SincedbValue.new(pos, exp, second_fingerprint)]
    end

    def parse_line_v1(parts)
      # old inode based e.g. 13377766,0,75 75 #{Time.now.to_f}
      kparts = parts.shift(3).map(&:to_i)
      pos, exp = parts
      exp = Float(exp) if !exp.nil?
      [InodeStruct.new(*kparts), SincedbValue.new(pos.to_i, exp)]
    end
  end
end
