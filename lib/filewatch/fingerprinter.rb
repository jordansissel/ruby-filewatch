require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class Fingerprinter
    attr_reader :data, :fnv, :fingerprint, :offset, :size

    def initialize(path, offset)
      @path = path
      @offset = offset
      @size = FP_BYTE_SIZE
    end

    def add_size(size)
      if @fnv
        fnv_fingerprint(size)
      end
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

    def data_size
      return 0 if @data.nil?
      @data.size
    end

    def to_a
      [@fingerprint, @offset, @size]
    end

    private

    def set_fingerprint(file)
      file.sysseek(@offset, IO::SEEK_SET)
      @data = file.sysread(FP_BYTE_SIZE)
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
