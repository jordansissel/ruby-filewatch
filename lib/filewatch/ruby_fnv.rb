# encoding: utf-8
# fnv code extracted and modified from https://github.com/jakedouglas/fnv-ruby
module FileWatch
  class Fnv
    INIT32  = 0x811c9dc5
    INIT64  = 0xcbf29ce484222325
    PRIME32 = 0x01000193
    PRIME64 = 0x100000001b3
    MOD32   = 2 ** 32
    MOD64   = 2 ** 64

    def self.coerce_bignum(i)
      # for compatibility with jruby impl
      i
    end

    def initialize(data)
      @bytes = data.bytes
      @size = data.bytesize
      @open = true
    end

    def fnv1a32(len = nil)
      raise StandardError.new("Fnv instance is closed!") if closed?
      common_fnv(len, INIT32, PRIME32, MOD32)
    end

    def fnv1a64(len = nil)
      raise StandardError.new("Fnv instance is closed!") if closed?
      common_fnv(len, INIT64, PRIME64, MOD64)
    end

    def close
      @open = false
      @data = nil
    end

    def closed?
      !@open
    end

    def open?
      @open
    end

    private

    def common_fnv(len, hash, prime, mod)
      arr = if !len.nil? && len < @size
              @bytes.take(len)
            else
              @bytes
            end

      arr.each do |byte|
        hash = hash ^ byte
        hash = (hash * prime) % mod
      end

      hash
    end

  end
end
