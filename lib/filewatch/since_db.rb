require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SinceDb
    def self.parse_line(line)
      parts = line.split(" ")
      parse_line_v2(parts) || parse_line_v1(parts)
    end

    def self.parse_line_v2(parts)
      return false if !parts.first.include?(",")
      fp1 = parts.shift.split(",").map(&:to_i)
      fp1[0] = Fnv.coerce_bignum(fp1[0])
      pos = parts.shift.to_i
      exp = Float(parts.shift)
      if !parts.empty?
        fp2 = parts.shift.split(",").map(&:to_i)
      end
      [SincedbKey2.new(*fp1), SincedbValue.new(pos, exp, fp2)]
    end

    def self.parse_line_v1(parts)
      kparts = parts.shift(3).map(&:to_i)
      pos, exp = parts
      exp = Float(exp) if !exp.nil?
      [SincedbKey1.new(*kparts), SincedbValue.new(pos.to_i, exp)]
    end

    def self.serialize_kv(k, v)
      "#{k} #{v}"
    end

    attr_reader :path, :short_keys
    attr_writer :logger

    def initialize(opts, loggr)
      @logger = loggr
      @path = opts[:sincedb_path]
      @lastwarn = Hash.new { |h, k| h[k] = 0 }
      @sincedb_last_write = 0
      @interval = opts[:sincedb_write_interval]
      @sincedb = {}
      @short_keys = Hash.new{|h, k| h[k] = []}
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
      @time_sdb_opened = Time.now.to_f
      begin
        File.open(path) do |db|
          @logger.debug? && @logger.debug("SinceDb open: reading from #{path}")
          db.each {|line| store_from_file(line) }
        end

        @logger.debug? && @logger.debug("SinceDb open: keys read #{@sincedb.keys.inspect}")
      rescue => e
        #No existing sincedb to load
        @logger.debug? && @logger.debug("SinceDb open: error: #{path}: #{e.inspect}")
      end
    end

    def deallocate(wf)
      return if !member?(wf.storage_key)
      get(wf.storage_key).clear_watched_file
    end

    def find(wf, event)
      @logger.debug? && @logger.debug("SinceDb find: event - #{event}")
      key = wf.storage_key
      value = get(key)
      if value
        @logger.debug? && @logger.debug("SinceDb find: found on first fp - #{key}:#{value}")
        # does the on disk record have a second fp?
        # then check it
        fp2 = value.second_fingerprint
        if fp2
          if !wf.last_fingerprint_match?(fp2)
            value = nil
          else
            @logger.debug? && @logger.debug("SinceDb find: matched on second fp:#{fp2}")
          end
        end
      end

      if value
        if value.watched_file.nil?
          # unallocated as read from disk
          @logger.debug? && @logger.debug("SinceDb find: allocating - #{value}")
          value.upd_watched_file(wf)
        elsif value.watched_file == wf
          @logger.debug? && @logger.debug("SinceDb find: exact match - #{value}")
          # or allocated to this watched_file via the SinceDbConnverter
          value.upd_expiry
        else
          @logger.debug? && @logger.debug("SinceDb find: match but allocated to another - #{value}")
          STDERR.puts ""
          # we found value having the same key as wf
          # wf is a renamed file recently discovered
          # or a different file with the same content
          # leave as is
        end
        @logger.debug? && @logger.debug("SinceDb find: returning value")
        return value
      end

      old_key = new_key = nil

      @short_keys.each do |k, vk|
        next if k >= key.size
        @logger.debug? && @logger.debug("SinceDb find: key: #{key}, short_keys - #{k}:#{vk}")
        # vk is a list of keys at size k
        old_key, new_key = wf.first_fingerprint_match_any?(vk.sort.reverse)
        # old_key is the one found via short_keys
        # new_key is the altered wf.storage key
        # it would have a new shorter fingerprint
        break if old_key && new_key # can't set during iteration
      end
      if old_key && new_key && member?(old_key)
        @logger.debug? && @logger.debug("SinceDb find: short keys match - #{old_key}, #{new_key}")
        value = delete(old_key)
        if value.watched_file.nil?
          @logger.debug? && @logger.debug("SinceDb find: short keys unallocated wf")
          value.upd_watched_file(wf)
        elsif value.watched_file != wf
          @logger.debug? && @logger.debug("SinceDb find: short keys allocated wf unequal")
          # put back
          set(old_key, value)
          # new value
          value = SincedbValue.new(value.position)
        else
          @logger.debug? && @logger.debug("SinceDb find: short keys allocated wf equal")
          # its the same watched file with a new key
          # nothing to do
        end
        set(new_key, value)
        @logger.debug? && @logger.debug("SinceDb find: found! - #{value}")
        return value
      end
      nil
    end

    def member?(key)
      @sincedb.member?(key)
    end

    def move(k1, k2)
      set(k2, delete(k1))
    end

    def get(key)
      @sincedb[key]
    end

    def delete(key)
      @sincedb.delete(key)
    end

    def last_read(key)
      @sincedb[key].position
    end

    def rewind(key)
      @sincedb[key].upd_position(0)
    end

    def store_last_read(key, last_read)
      @sincedb[key].upd_position(last_read)
    end

    def increment(key, amount)
      @sincedb[key].inc_position(amount)
    end

    def add_watched_file(key, wf)
      @sincedb[key].upd_watched_file(wf)
    end

    def clear
      @sincedb.clear
    end

    def keys
      @sincedb.keys
    end

    def set(key, value)
      @sincedb[key] = value
      if key.version?(2) && key.short?
        @short_keys[key.size] << key
      end
      value
    end

    def unallocated?(key)
      return false if !member?(key)
      get(key).watched_file.nil?
    end

    private

    def store_from_file(line)
      key, value = self.class.parse_line(line)
      if @time_sdb_opened < value.expires
        @logger.debug? && @logger.debug("SinceDb open: setting #{key.inspect} to #{value.inspect}")
        set(key, value)
      else
        @logger.debug? && @logger.debug("SinceDb open: expired, ignoring #{key.inspect} to #{value.inspect}")
      end
    end

    def serialize
      @sincedb.map do |key, value|
        self.class.serialize_kv(key, value)
      end.join("\n") + "\n"
    end

    def sincedb_write
      begin
        if HOST_OS_WINDOWS || File.device?(path)
          IO.write(path, serialize, 0)
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
