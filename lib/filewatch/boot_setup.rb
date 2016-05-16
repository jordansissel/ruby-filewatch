# encoding: utf-8
require "rbconfig"

## Common setup
#  all the required constants and files
#  defined in one place
module FileWatch
  HOST_OS_WINDOWS = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) != nil
  # the standard fingerprint size
  # this is the number of bytes read to compute the fingerprint
  FP_BYTE_SIZE = 255
  # the number of bytes read from a file during the read phase
  FILE_READ_SIZE = 32768
  # each sincedb record will expire unless it is seen again
  # this is the number of days a record needs
  # to be stale before it is considered gone
  SDB_EXPIRES_DAYS = 10
  # the largest fixnum in ruby
  # this is used in the read loop e.g.
  # @opts[:read_iterations].times do
  # where read_iterations defaults to this constant
  FIXNUM_MAX = (2**(0.size * 8 - 2) - 1)

  require "filewatch/helper"

  if HOST_OS_WINDOWS
    require "filewatch/winhelper"
    FILEWATCH_INODE_METHOD = :win_inode
  else
    FILEWATCH_INODE_METHOD = :nix_inode
  end

  if defined?(JRUBY_VERSION)
    require "java"
    require "jars/jruby-filewatch-library.jar"
    require "jruby_file_watch"
  else
    require "filewatch/ruby_fnv"
  end

  if HOST_OS_WINDOWS && defined?(JRUBY_VERSION)
    FileOpener = FileExt
  else
    FileOpener = ::File
  end

  # Structs can be used as hash keys because they compare by value
  # this is used as the key for values in the sincedb hash
  InodeStruct = Struct.new(:inode, :maj, :min) do
    def fp() nil; end
    def offset() 0; end
    def size() 0; end
    def version?(i) i == 1; end
    def to_s() to_a.join(" "); end
  end

  # this is a value object created when a
  # sincedb record is read and it has a second fingerprint
  FingerprintStruct = Struct.new(:fp, :offset, :size) do
    include Comparable
    def <=>(other)
      v = other.size <=> size
      return v if v != 0
      v = other.offset <=> offset
      return v if v != 0
      other.fp <=> fp
    end
    def version?(i) i == 2; end
    def short?() size < FP_BYTE_SIZE; end
    def to_s() to_a.join(","); end
    def offset_eq?(some_offset)
      offset == some_offset
    end
    def to_h
      {"hash" => fp, "offset" => offset, "size" => size}
    end
  end

  # this value object is passed from discover
  # to each watched file as it is created
  class WatchedFileConfig
    attr_reader :delimiter, :close_older, :ignore_older

    def initialize(delim, close_o, ignore_o)
      @delimiter = delim
      @close_older = coerce_float_with_nil(close_o)
      @ignore_older = coerce_float_with_nil(ignore_o)
    end

    private

    def coerce_float_with_nil(value)
      #nil is allowed but 0 and negatives are made nil
      return nil if value.nil?
      val = value.to_f
      val <= 0 ? nil : val
    end
  end

  class NoSinceDBPathGiven < StandardError; end
  class SubclassMustImplement < StandardError; end
  # how often (in seconds) we @logger.warn a failed file open, per path.
  OPEN_WARN_INTERVAL = ENV.fetch("FILEWATCH_OPEN_WARN_INTERVAL", 300).to_i
  MAX_FILES_WARN_INTERVAL = ENV.fetch("FILEWATCH_MAX_FILES_WARN_INTERVAL", 20).to_i

  require "filewatch/buftok"
  require "filewatch/fingerprinter"
  require "filewatch/watched_file"
  require "filewatch/discover"
  require "filewatch/serializer_base"
  require "filewatch/space_separated_serializer"
  require "filewatch/json_serializer"
  require "filewatch/sincedb_value"
  require "filewatch/since_db"
  require "filewatch/since_db_converter"

  require "filewatch/watch"
  require "filewatch/tail_base"
  require "filewatch/tail"

  require "logger"

  # TODO [guy] make this a config option, perhaps.
  CurrentSerializer = SpaceSeparatedSerializer

  # these classes are used if the caller does not
  # supply their own observer and listener
  # which would be a programming error when coding against
  # observable_tail
  class NullListener
    def initialize(path) @path = path; end
    def accept(line) end
    def deleted() end
    def created() end
    def error() end
    def eof() end
    def timed_out() end
  end

  class NullObserver
    def listener_for(path) NullListener.new(path); end
  end
end
