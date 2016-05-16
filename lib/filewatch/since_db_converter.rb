# encoding: utf-8
require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class SinceDbConverter
    attr_reader :sincedb, :converted_records
    attr_writer :logger

    def initialize(sdb, loggr)
      @sincedb = sdb
      @logger = loggr
      @sincedb.open
      @converted_records = 0
    end

    def write_converted_sincedb
      @sincedb.write("converted old records: #{@converted_records}")
    end

    # this method is called on each discovered watched file
    # we look for a sincedb entry from disk for this watched file
    def convert_watched_file(wf)
      key1 = wf.sdb_key_v1
      key2 = wf.storage_key
      # is there a v1 record but no v2 record?
      # then simply delete old key, update val and set new key
      present1 = @sincedb.member?(key1)
      present2 = @sincedb.member?(key2)

      hk1 = @sincedb.keys.first

      @logger.debug? && @logger.debug("SinceDbConverter convert: wf: #{wf.path}, k1: #{key1}, k2: #{key2}, k1?: #{present1}, k2?: #{present2}")
      if present1 && !present2
        sdb_val = @sincedb.delete(key1)
        @logger.debug? && @logger.debug("SinceDbConverter convert: key1 - value: #{sdb_val}")
        wf.update_bytes_read(sdb_val.position)
        sdb_val.set_watched_file(wf)
        @sincedb.set(key2, sdb_val)
        wf.ignore if wf.read_all?
        @converted_records += 1
      elsif present2
        sdb_val = @sincedb.find(wf, :convert)
        if sdb_val
          @logger.debug? && @logger.debug("SinceDbConverter convert: key2 - value: #{sdb_val}")
          # wf bytes_read was done by the find method
          if wf.read_all?
            @logger.debug? && @logger.debug("SinceDbConverter convert: wf has all bytes read, setting to ignore")
            wf.ignore
          end
        end
      end
    end
  end
end
