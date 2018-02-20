# encoding: utf-8
require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SinceDb

    attr_reader :path, :short_keys
    attr_writer :logger, :serializer

    def initialize(opts, loggr)
      @logger = loggr
      @path = opts[:sincedb_path]
      @sincedb_last_write = 0
      @interval = opts[:sincedb_write_interval]
      @sincedb = {}
      # see #set and #find for usage
      # when ever a sincedb record is seen that is less than FP_BYTE_SIZE
      # we store it in this hash.
      # it is keyed on size, e.g. all keys of 100 length are in the array
      # e.g. @short_keys[100] -> [k1, k2, k3]
      # this is because a record can be created when the file was smaller, say 100
      # but now, when we see the file again, it has grown, so its key is at 255
      # we will not find this 255 based key in the sincedb so we need to
      # check whether any of the short keys might be the matching record
      # because we want to start reading at the last position.
      # If we find a short_key we remove it.
      @short_keys = Hash.new{|h, k| h[k] = []}
      @serializer = CurrentSerializer.new
    end

    def request_disk_flush
      now = Time.now.to_i
      delta = now - @sincedb_last_write
      if delta >= @interval
        @logger.debug? && @logger.debug("writing sincedb (delta since last write = #{delta})")
        sincedb_write(now)
      end
    end

    def write(reason=nil)
      @logger.debug? && @logger.debug("caller requested sincedb write (#{reason})")
      sincedb_write
    end

    def open
      @time_sdb_opened = Time.now.to_f
      begin
        File.open(path) do |file|
          @logger.debug? && @logger.debug("SinceDb open: reading from #{path}")
          @serializer.deserialize(file) do |key, value|
            load_key_value(key, value)
          end
        end
        @logger.debug? && @logger.debug("SinceDb open: keys read #{@sincedb.keys.inspect}")
      rescue => e
        #No existing sincedb to load
        @logger.debug? && @logger.debug("SinceDb open: error: #{path}: #{e.inspect}")
      end
    end

    def direct_key_membership(wf)
      key = wf.storage_key
      value = get(key)
      if value
        @logger.debug? && @logger.debug("SinceDb find: found on first fp - #{key} => #{value}")
        # does the on disk record have a second fp?
        # then check it
        fp2 = value.second_fingerprint
        if fp2
          if !wf.last_fingerprint_match?(fp2)
            return nil
          else
            @logger.debug? && @logger.debug("SinceDb find: matched on second fp:#{fp2}")
            # we found a multiple fp match
            # set the value watched_file
            if value.watched_file.nil?
              # unallocated as read from disk
              @logger.debug? && @logger.debug("SinceDb find: allocating - #{value}")
              wf.update_bytes_read(value.position)
              value.set_watched_file(wf)
            elsif value.watched_file == wf
              @logger.debug? && @logger.debug("SinceDb find: exact match - #{value}")
              # or allocated to this watched_file via the SinceDbConnverter v1 conversion
              value.upd_expiry
            else
              @logger.debug? && @logger.debug("SinceDb find: match but allocated to another - #{value}")
              # we found value having the same key as wf
              # wf is a renamed file recently discovered
              # or a different file with the same content
              # leave as is
            end
            @logger.debug? && @logger.debug("SinceDb find: returning value")
          end
        end
      end
      value
    end

    def indirect_short_key_membership(wf)
      key = wf.storage_key
      old_key = new_key = nil
      @short_keys.each do |k, vk|
        next if k >= key.size
        @logger.debug? && @logger.debug("SinceDb find: key: #{key}, short_keys - #{k}:#{vk}")
        # vk is a list of keys at size k
        old_key, new_key = wf.first_fingerprint_match_any?(vk.sort)
        # old_key is the one found via short_keys
        # new_key is the wf.storage key
        break if old_key && new_key # can't mutate @short_keys during iteration
      end
      if old_key && new_key && member?(old_key)
        @logger.debug? && @logger.debug("SinceDb find: short keys match - #{old_key}, #{new_key}")
        value = delete(old_key)
        if value.watched_file.nil?
          @logger.debug? && @logger.debug("SinceDb find: short keys unallocated wf")
          wf.update_bytes_read(value.position)
          value.set_watched_file(wf)
        elsif value.watched_file != wf
          @logger.debug? && @logger.debug("SinceDb find: short keys allocated wf unequal")
          # put back
          set(old_key, value)
          # new value
          value = SincedbValue.new(0) # allow the new allocation to start from scratch
          value.set_watched_file(wf)
        else
          @logger.debug? && @logger.debug("SinceDb find: short keys allocated wf equal")
          # its the same watched file with a new key
          # nothing to do
        end
        set(new_key, value)
        @logger.debug? && @logger.debug("SinceDb find: found! - #{value}")
        return value
      end
      @logger.debug? && @logger.debug("SinceDb find: NOT FOUND!, path: #{wf.path}")
      nil
    end

    def find(wf, event)
      @logger.debug? && @logger.debug("SinceDb find: event: #{event}, path: #{wf.path}")
      direct_key_membership(wf) || indirect_short_key_membership(wf)
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

    def set_watched_file(key, wf)
      @sincedb[key].set_watched_file(wf)
    end

    def unset_watched_file(wf)
      return if !member?(wf.storage_key)
      get(wf.storage_key).unset_watched_file
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

    def watched_file_unset?(key)
      return false if !member?(key)
      get(key).watched_file.nil?
    end

    private

    def last_seen_at_expires(last_seen_at)
      last_seen_at + SDB_EXPIRES_DAYS * (24 * 3600)
    end

    def load_key_value(key, value)
      if @time_sdb_opened < last_seen_at_expires(value.last_seen_at)
        @logger.debug? && @logger.debug("SinceDb open: setting #{key.inspect} to #{value.inspect}")
        set(key, value)
      else
        @logger.debug? && @logger.debug("SinceDb open: expired, ignoring #{key.inspect} to #{value.inspect}")
      end
    end

    def sincedb_write(_when = Time.now.to_i)
      begin
        if HOST_OS_WINDOWS || FileHelper.device?(path)
          IO.write(path, @serializer.serialize(@sincedb), 0)
        else
          FileHelper.write_atomically(path) {|file| file.write(@serializer.serialize(@sincedb)) }
        end
        @sincedb_last_write = _when
      rescue Errno::EACCES
        # probably no file handles free
        # maybe it will work next time
        @logger.debug? && @logger.debug("_sincedb_write: error: #{path}: #{$!}")
      end
    end
  end
end
