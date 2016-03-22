require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SinceDb

    attr_reader :path

    def initialize(opts, loggr)
      @logger = loggr
      @path = opts[:sincedb_path]
      @lastwarn = Hash.new { |h, k| h[k] = 0 }
      @sincedb_last_write = 0
      @interval = opts[:sincedb_write_interval]
      @sincedb = {}
    end

    def write_periodically
      now = Time.now.to_i
      delta = now - @sincedb_last_write
      if delta >= @interval
        @logger.debug? && @logger.debug("writing sincedb (delta since last write = #{delta})")
        sincedb_write
        @sincedb_last_write = now
      end
    end

    def write(reason=nil)
      @logger.debug? && @logger.debug("caller requested sincedb write (#{reason})")
      sincedb_write
    end

    def open
      begin
        File.open(path) do |db|
          @logger.debug? && @logger.debug("sincedb_open: reading from #{path}")
          db.each {|line| store(line) }
        end
      rescue => e
        #No existing sincedb to load
        @logger.debug? && @logger.debug("sincedb_open: error: #{path}: #{e.inspect}")
      end
    end

    def member?(wf)
      @sincedb.member?(storage_key(wf))
    end

    def last_read(wf)
      @sincedb[storage_key(wf)]
    end

    def rewind(wf)
      @sincedb[storage_key(wf)] = 0
    end

    def store_last_read(wf, last_read)
      @sincedb[storage_key(wf)] = last_read
    end

    def increment(wf, amount)
      @sincedb[storage_key(wf)] += amount
    end

    def clear
      @sincedb.clear
    end

    def version_match?(line)
      !split_line(line.size).first.include?("|")
    end

    def keys
      @sincedb.keys
    end

    private

    def split_line(line)
      line.split(" ", 4)
    end

    def storage_key(wf)
      wf.sdb_key_v1
    end

    def store(line)
      k, maj, min, pos = split_line(line)
      key = "#{k} #{maj} #{min}"
      @logger.debug? && @logger.debug("sincedb_open: setting #{key.inspect} to #{pos.to_i}")
      @sincedb[key] = pos.to_i
    end

    def serialize
      @sincedb.map do |key, pos|
        "#{key} #{pos}"
      end.join("\n") + "\n"
    end

    def sincedb_write
      begin
        if HOST_OS_WINDOWS || File.device?(path)
          IO.write(path, serialize_sincedb, 0)
        else
          File.write_atomically(path) {|file| file.write(serialize) }
        end
      rescue Errno::EACCES
        # probably no file handles free
        # maybe it will work next time
        @logger.debug? && @logger.debug("_sincedb_write: error: #{path}: #{$!}")
      end
    end
  end
end
