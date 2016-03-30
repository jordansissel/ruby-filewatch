require "rbconfig"

module FileWatch
  HOST_OS_WINDOWS = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) != nil

  FP_BYTE_SIZE = 255
  FILE_READ_SIZE = 32768
  SDB_EXPIRES_DAYS = 10
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

  FakeStat = Struct.new(:size, :mtime)

  # Structs can be used as hash keys because they compare by value
  SincedbKey1 = Struct.new(:inode, :maj, :min) do
    def fp() nil; end
    def offset() 0; end
    def size() 0; end
    def version?(i) i == 1; end
    def to_s() to_a.join(" "); end
  end

  SincedbKey2 = Struct.new(:fp, :offset, :size) do
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
  end

  class NoSinceDBPathGiven < StandardError; end
  # how often (in seconds) we @logger.warn a failed file open, per path.
  OPEN_WARN_INTERVAL = ENV.fetch("FILEWATCH_OPEN_WARN_INTERVAL", 300).to_i
  MAX_FILES_WARN_INTERVAL = ENV.fetch("FILEWATCH_MAX_FILES_WARN_INTERVAL", 20).to_i

  require "filewatch/buftok"
  require "filewatch/fingerprinter"
  require "filewatch/watched_file"
  require "filewatch/discover"
  require "filewatch/sincedb_value"
  require "filewatch/since_db"
  require "filewatch/since_db_converter"

  require "filewatch/watch"
  require "filewatch/tail_base"
  require "filewatch/tail"

  require "logger"

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
