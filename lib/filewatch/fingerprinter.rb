require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class Fingerprinter
    attr_reader :data, :fnv, :fingerprint, :offset, :size

    def initialize(path, offset)
      @path = path
      @offset = offset
      @size = FP_BYTE_SIZE
    end

    def match_any?(keys)
      if @fnv.nil?
        # STDERR.puts "Fingerprinter: fnv nil for path - #{path}"
        return nil
      end
      if @data.nil?
        # STDERR.puts "Fingerprinter: data nil for path - #{path}"
        return nil
      end
      keys.each do |k|
        fp, off, len = *k
        # STDERR.puts "Fingerprinter: any_match? - #{fp}:#{off}:#{len}"
        if off != @offset
          # STDERR.puts "Fingerprinter: any_match? - wrong offset, mine is: #{@offset}"
          next
        end
        possible = @fnv.fnv1a64(len)
        if fp == possible
          @fingerprint, @size = fp, len
          return k
        end
      end
      # STDERR.puts "Fingerprinter: no match - #{keys.inspect}"
      nil
    end

    def add_size(size)
      if @fnv
        fnv_fingerprint(size)
      end
      self
    end

    def add_data(data)
      @data = data
      set_fnv
      self
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
      set_fingerprint(file)
      self
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

    def starts_eql?(other)
      return false if offset != other.offset
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
      set_fnv
    end

    def set_fnv
      @fnv = Fnv.new(@data)
      fnv_fingerprint(@size)
    end

    def fnv_fingerprint(size)
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
