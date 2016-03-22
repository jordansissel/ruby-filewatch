require "rbconfig"

module FileWatch
  HOST_OS_WINDOWS = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) != nil

  FP_BYTE_SIZE = 255
  FILE_READ_SIZE = 32768
  SDB_EXPIRES_DAYS = 10

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
  require "filewatch/since_db_v2"
  require "filewatch/since_db_upgrader"

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
