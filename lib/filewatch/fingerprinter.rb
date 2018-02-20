# encoding: utf-8
require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class Fingerprinter
    attr_reader :data, :fnv, :fingerprint, :offset, :size

    # construction will yield a 'blank' object
    # use read_path, or read_file or add_data
    # to fully initialize the object
    def initialize(path, offset)
      @path = path
      @offset = offset
      # @size should never be zero.
      # it defaults to FP_BYTE_SIZE unless called to be
      # smaller during secondary fingerprint matching.
      @size = FP_BYTE_SIZE
    end

    def read_path
      begin
        file = FileOpener.open(@path)
        set_fingerprint(file)
      ensure
        file.close
      end
      self
    end

    def read_file(file)
      begin
        dup = file.dup
        set_fingerprint(dup)
      ensure
        dup.close if dup
      end
      self
    end

    # use this method if you have read some data already
    # maybe as part of the file reading behaviour
    def add_data(data)
      @data = data
      set_mechanism_and_take_fingerprint
      self
    end

    # use this method to add the size of data you want the fingerprint
    # to be taken on - but only if you need a smaller size than FP_BYTE_SIZE
    # you must construct the fingerprinter first then call read_path, read_file or add_data
    def add_size(new_size)
      if @fnv
        set_fingerprint_at(new_size)
      end
      self
    end

    # keys are an array of sincedb keys that could be a match
    # on the data that this fingerprinter holds
    # each key is a FingerprintStruct instance and should point
    # to a sincedb record that has not been matched yet
    def match_any?(keys)
      # has a fingerprint been generated for this path, offset and size yet?
      return nil if @fnv.nil? || @data.nil?
      # we are only interested in possible sincedb (record) keys that
      # were taken at the same offset
      keys.select{|k| k.offset_eq?(@offset)}.each do |candidate_key|
        candidate_fingerprint, candidate_offset, candidate_size = *candidate_key # calls to_a on FingerprintStruct
        mine_at_candidate_size = fingerprint_at(candidate_size)
        if candidate_fingerprint == mine_at_candidate_size
          # make this one equal the key in the sincedb
          # @fingerprint = mine_at_candidate_size
          # @size = candidate_size
          return candidate_key # found one!
        end
      end
      nil
    end

    def ==(other)
      size == other.size && offset == other.offset && fingerprint == other.fingerprint
    end

    def data_size
      return 0 if @data.nil?
      @data.size
    end

    def to_a
      [@fingerprint, @offset, @size]
    end

    def to_struct
      FingerprintStruct.new(to_a)
    end

    def to_io
      StringIO.new(@data)
    end

    def clear
      @data = @fnv = nil
    end

    def end_position
      @offset + @size
    end

    def fingerprint_at(len)
      @fnv.fnv1a64(len)
    end

    def equivalent?(other)
      return false if offset != other.offset
      # if we have two fingerprints at the same offset but
      # one has been taken at a smaller size than the other
      # check equivalence by taking a fingerprint in the larger one
      # at the smaller ones size.
      if size > other.size
        return fingerprint_at(other.size) == other.fingerprint
      end
      if other.size > size
        return other.fingerprint_at(size) == fingerprint
      end
      other.fingerprint == fingerprint
    end

    private

    def set_fingerprint(file)
      file.sysseek(@offset, IO::SEEK_SET)
      @data = file.sysread(FP_BYTE_SIZE)
      set_mechanism_and_take_fingerprint
    end

    def set_mechanism_and_take_fingerprint
      set_fp_mechanism
      set_fingerprint_at(@size)
    end

    def set_fp_mechanism
      @fnv = Fnv.new(@data)
    end

    def set_fingerprint_at(size)
      # Is the size arg usable?
      #   it can't be nil and
      #   it must be less than 256 and
      #   it must be less than the size of the data we have been given.

      # if its usable
      # then store the given size and take a fingerprint at the given size
      # else store the data.size and take a fingerprint at the natural size (data.size)
      if size && size < FP_BYTE_SIZE && size < data_size
        @size = size
        @fingerprint = @fnv.fnv1a64(@size)
      else
        @size = data_size
        @fingerprint = @fnv.fnv1a64
      end
    end
  end
end

__END__

Why FNV and not SHA256 or similar.
I considered non-cryptographic and cryptographic hash algorithms.
Non-cryptographic:
FNV, Jenkins, Hsieh, Murmur

Cryptographic:
SHA256

My main consideration was collision likelyhood and
a second consideration is whether a MRI implemetation
was available and whether we had to code it and if so,
how complex would it be to code.

I chose FNV because it has low collision likelyhood and easy to code.
However, we could just fork this library for LS and make it JRuby only.

See http://eternallyconfuzzled.com/tuts/algorithms/jsw_tut_hashing.aspx


