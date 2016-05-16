require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  if defined?(Logstash)
    require "logstash/json"
    Json = Logstash::Json
  else
    require "json"
    Json = JSON
  end

  class JsonSerializer < SerializerBase
    module KEYS
      POSITION = "position".freeze
      LAST_SEEN = "last_seen".freeze
      FINGERPRINTS = "fingerprints".freeze
      PATH = "path".freeze
      STATE = "state".freeze
      INODE = "inode".freeze
      DEVICE_MINOR = "device_minor".freeze
      DEVICE_MAJOR = "device_major".freeze
      IDX_HI = "idxhi".freeze
      IDX_LO = "idxlo".freeze
      VOL = "vol".freeze
      ALGO = "algo".freeze
      HASH = "hash".freeze
      OFFSET = "offset".freeze
      SIZE = "size".freeze
      VERSION = "version".freeze

      def self.join_win_inode(hash)
        "#{hash[VOL]}-#{hash[IDX_LO]}-#{hash[IDX_HI]}"
      end
    end

    def serialize(db)
      array = db.map do |key, value|
        serialize_record(key, value)
      end
      array.unshift({KEYS::VERSION => "1.0"})
      Json.dump(array)
    end

    def deserialize(io)
      array = Json.load(io)
      ver = array.shift
      #TODO test version
      array.each do |record|
        yield deserialize_record(record)
      end
    end

    def serialize_record(key, value)
      hash = {
        KEYS::POSITION => value.position,
        KEYS::LAST_SEEN => value.last_seen_at,
        KEYS::FINGERPRINTS => fingerprints_to_hash_array(key, value)
      }
      add_watched_file_info(hash, value)
      hash
    end

    def deserialize_record(record)
      parse_line_v2(record) || parse_line_v1(record)
    end

    private

    def add_watched_file_info(hash, value)
      wf = value.watched_file
      hash[KEYS::PATH] = wf.nil? ? "" : wf.path
      hash[KEYS::STATE] = inode_to_hash(wf)
    end

    def fingerprints_to_hash_array(key, value)
      a = []
      return a if key.version?(1)
      a << key.to_h.tap {|h| h[KEYS::ALGO] = "fnv"}
      if !value.second_fingerprint.nil?
        a << value.second_fingerprint.to_h.tap {|h| h[KEYS::ALGO] = "fnv"}
      end
      a
    end

    def parse_line_v2(record)
      fingerprints = Array(record[KEYS::FINGERPRINTS])
      return false if fingerprints.empty?

      key = build_fingerprint_struct(fingerprints, 0)
      second_fingerprint = build_fingerprint_struct(fingerprints, 1)
      value = SincedbValue.new(
        record[KEYS::POSITION].to_i,
        record[KEYS::LAST_SEEN].to_f,
        second_fingerprint
      )
      [key, value]
    end

    def parse_line_v1(record)
      inode_hash = record[KEYS::STATE]
      value = SincedbValue.new(
        record[KEYS::POSITION].to_i,
        record[KEYS::LAST_SEEN].to_f
      )
      key = if HOST_OS_WINDOWS
          InodeStruct.new(KEYS.join_win_inode(inode_hash), 0, 0)
        else
          InodeStruct.new(
            inode_hash[KEYS::INODE].to_i,
            inode_hash[KEYS::DEVICE_MINOR].to_i,
            inode_hash[KEYS::DEVICE_MAJOR].to_i,
          )
        end
      [key, value]
    end

    def build_fingerprint_struct(array, index)
      return nil if index >= array.size
      FingerprintStruct.new(
        Fnv.coerce_bignum(fingerprints[0][KEYS::HASH]),
        array[index][KEYS::OFFSET].to_i,
        array[index][KEYS::SIZE].to_i,
      )
    end

    def inode_to_hash(wf)
      return {} if wf.nil?
      if HOST_OS_WINDOWS
        inode_to_win_hash(wf)
      else
        inode_to_nix_hash(wf)
      end
    end

    def inode_to_nix_hash(wf)
      {
        KEYS::INODE => "#{wf.inode[0]}",
        KEYS::DEVICE_MINOR => "#{wf.inode[2]}",
        KEYS::DEVICE_MAJOR => "#{wf.inode[1]}",
      }
    end

    def inode_to_win_hash(wf)
      parts = wf.inode[0].split("-")
      {
        KEYS::VOL => "#{parts[0]}",
        KEYS::IDX_LO => "#{parts[1]}",
        KEYS::IDX_HI => "#{parts[2]}",
      }
    end
  end
end
