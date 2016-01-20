require "filewatch/helper"
require "filewatch/watch"

if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
  require "filewatch/winhelper"
end
require "logger"
require "rbconfig"

include Java if defined? JRUBY_VERSION
require "JRubyFileExtension.jar" if defined? JRUBY_VERSION

module FileWatch
  module TailBase
    # how often (in seconds) we @logger.warn a failed file open, per path.
    OPEN_WARN_INTERVAL = ENV["FILEWATCH_OPEN_WARN_INTERVAL"] ?
                         ENV["FILEWATCH_OPEN_WARN_INTERVAL"].to_i : 300

    attr_reader :logger

    class NoSinceDBPathGiven < StandardError; end

    public
    def initialize(opts={})
      @iswindows = ((RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) != nil)

      if opts[:logger]
        @logger = opts[:logger]
      else
        @logger = Logger.new(STDERR)
        @logger.level = Logger::INFO
      end
      @lastwarn = Hash.new { |h, k| h[k] = 0 }
      @buffers = {}
      @watch = FileWatch::Watch.new
      @watch.logger = @logger
      @sincedb = {}
      @sincedb_last_write = 0
      # @statcache = {}
      @opts = {
        :sincedb_write_interval => 10,
        :stat_interval => 1,
        :discover_interval => 5,
        :exclude => [],
        :start_new_files_at => :end,
        :delimiter => "\n"
      }.merge(opts)
      if !@opts.include?(:sincedb_path)
        @opts[:sincedb_path] = File.join(ENV["HOME"], ".sincedb") if ENV.include?("HOME")
        @opts[:sincedb_path] = ENV["SINCEDB_PATH"] if ENV.include?("SINCEDB_PATH")
      end
      if !@opts.include?(:sincedb_path)
        raise NoSinceDBPathGiven.new("No HOME or SINCEDB_PATH set in environment. I need one of these set so I can keep track of the files I am following.")
      end
      @watch.exclude(@opts[:exclude])
      @watch.close_older = @opts[:close_older]
      @watch.ignore_older = @opts[:ignore_older]
      @watch.delimiter = @opts[:delimiter]
      @watch.max_open_files = @opts[:max_open_files]
      @delimiter_byte_size = @opts[:delimiter].bytesize

      _sincedb_open
    end # def initialize

    public
    def logger=(logger)
      @logger = logger
      @watch.logger = logger
    end # def logger=

    public
    def tail(path)
      @watch.watch(path)
    end # def tail

    public
    def sincedb_record_uid(path, stat)
      # retain this call because its part of the public API
      @watch.inode(path,stat)
    end # def sincedb_record_uid

    private

    def _open_file(watched_file, event)
      path = watched_file.path
      debug_log("_open_file: #{path}: opening")
      begin
        if @iswindows && defined? JRUBY_VERSION
          watched_file.file_add_opened(Java::RubyFileExt::getRubyFile(path))
        else
          watched_file.file_add_opened(File.open(path))
        end
      rescue
        # don't emit this message too often. if a file that we can't
        # read is changing a lot, we'll try to open it more often,
        # and might be spammy.
        now = Time.now.to_i
        if now - @lastwarn[path] > OPEN_WARN_INTERVAL
          @logger.warn("failed to open #{path}: #{$!}")
          @lastwarn[path] = now
        else
          debug_log("(warn supressed) failed to open #{path}: #{$!.inspect}")
        end
        watched_file.watch # set it back to watch so we can try it again
        return false
      end
      _add_to_sincedb(watched_file, event)
      true
    end # def _open_file

    def _add_to_sincedb(watched_file, event)
      stat = watched_file.filestat
      sincedb_key = watched_file.inode
      path = watched_file.path

      if @sincedb.member?(sincedb_key)
        last_size = @sincedb[sincedb_key]
        debug_log("#{path}: sincedb last value #{@sincedb[sincedb_key]}, cur size #{stat.size}")
        if last_size <= stat.size
          debug_log("#{path}: sincedb: seeking to #{last_size}")
          watched_file.file_seek(last_size)
        else
          debug_log("#{path}: last value size is greater than current value, starting over")
          @sincedb[sincedb_key] = 0
        end
      elsif event == :create_initial
        if @opts[:start_new_files_at] == :beginning
          debug_log("#{path}: initial create, no sincedb, seeking to beginning of file")
          watched_file.file_seek(0)
          @sincedb[sincedb_key] = 0
        else
          # seek to end
          debug_log("#{path}: initial create, no sincedb, seeking to end #{stat.size}")
          watched_file.file_seek(stat.size)
          @sincedb[sincedb_key] = stat.size
        end
      elsif event == :create
        @sincedb[sincedb_key] = 0
      elsif event == :modify && @sincedb[sincedb_key].nil?
        @sincedb[sincedb_key] = 0
      elsif event == :unignore
        @sincedb[sincedb_key] = watched_file.ignored_size
      else
        debug_log("#{path}: staying at position 0, no sincedb")
      end
      return true
    end # def _add_to_sincedb

    public
    def sincedb_write(reason=nil)
      debug_log("caller requested sincedb write (#{reason})")
      _sincedb_write
    end

    private
    def _sincedb_open
      path = @opts[:sincedb_path]
      begin
        File.open(path) do |db|
          debug_log("_sincedb_open: reading from #{path}")
          db.each do |line|
            ino, dev_major, dev_minor, pos = line.split(" ", 4)
            sincedb_key = [ino, dev_major.to_i, dev_minor.to_i]
            debug_log("_sincedb_open: setting #{sincedb_key.inspect} to #{pos.to_i}")
            @sincedb[sincedb_key] = pos.to_i
          end
        end
      rescue
        #No existing sincedb to load
        debug_log("_sincedb_open: error: #{path}: #{$!}")
      end
    end # def _sincedb_open

    private
    def _sincedb_write
      path = @opts[:sincedb_path]
      begin
        if @iswindows || File.device?(path)
          IO.write(path, serialize_sincedb, 0)
        else
          File.atomic_write(path) {|file| file.write(serialize_sincedb) }
        end
      rescue Errno::EACCES
        # probably no file handles free
        # maybe it will work next time
        debug_log("_sincedb_write: error: #{path}: #{$!}")
      end
    end # def _sincedb_write

    public
    # quit is a sort-of finalizer,
    # it should be called for clean up
    # before the instance is disposed of.
    def quit
      @watch.quit # <-- should close all the files
      # and that should allow the sincedb_write to succeed if it could not before
      _sincedb_write
    end # def quit

    public

    # close_file(path) is to be used by external code
    # when it knows that it is completely done with a file.
    # Other files or folders may still be being watched.
    # Caution, once unwatched, a file can't be watched again
    # unless a new instance of this class begins watching again.
    # The sysadmin should rename, move or delete the file.
    def close_file(path)
      @watch.unwatch(path)
      _sincedb_write
    end

    private
    def serialize_sincedb
      @sincedb.map do |inode, pos|
        [inode, pos].flatten.join(" ")
      end.join("\n") + "\n"
    end

    def debug_log(msg)
      return unless @logger.debug?
      @logger.debug(msg)
    end
  end # module TailBase
end # module FileWatch
