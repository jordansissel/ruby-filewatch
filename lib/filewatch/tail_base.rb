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
    OPEN_WARN_INTERVAL = ENV.fetch("FILEWATCH_OPEN_WARN_INTERVAL", 300).to_i

    attr_reader :logger

    class NoSinceDBPathGiven < StandardError; end

    public
    # TODO move sincedb to watch.rb
    # see TODO there
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
      @sincedb_last_write = 0
      @sincedb = {}
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
      @watch.inode(path, stat)
    end # def sincedb_record_uid

    private

    def _open_file(watched_file, event)
      path = watched_file.path
      @logger.debug? && @logger.debug("_open_file: #{path}: opening")
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
          @logger.debug? && @logger.debug("(warn supressed) failed to open #{path}: #{$!.inspect}")
        end
        watched_file.watch # set it back to watch so we can try it again
        return false
      end
      _add_to_sincedb(watched_file, event)
      true
    end # def _open_file

    def _add_to_sincedb(watched_file, event)
      # called when newly discovered files are opened
      stat = watched_file.filestat
      sincedb_key = watched_file.inode
      path = watched_file.path

      if @sincedb.member?(sincedb_key)
        # we have seen this inode before
        # but this is a new watched_file
        # and we can't tell if its contents are the same
        # as another file we have watched before.
        last_read_size = @sincedb[sincedb_key]
        @logger.debug? && @logger.debug("#{path}: sincedb last value #{@sincedb[sincedb_key]}, cur size #{stat.size}")
        if stat.size > last_read_size
          # 1) it could really be a new file with lots of new content
          # 2) it could have old content that was read plus new that is not
          @logger.debug? && @logger.debug("#{path}: sincedb: seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size) # going with 2
          watched_file.update_bytes_read(last_read_size)
        elsif stat.size == last_read_size
          # 1) it could have old content that was read
          # 2) it could have new content that happens to be the same size
          @logger.debug? && @logger.debug("#{path}: sincedb: seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size) # going with 1.
          watched_file.update_bytes_read(last_read_size)
        else
          # it seems to be a new file with less content
          @logger.debug? && @logger.debug("#{path}: last value size is greater than current value, starting over")
          @sincedb[sincedb_key] = 0
          watched_file.update_bytes_read(0) if watched_file.bytes_read != 0
        end
      elsif event == :create_initial
        if @opts[:start_new_files_at] == :beginning
          @logger.debug? && @logger.debug("#{path}: initial create, no sincedb, seeking to beginning of file")
          watched_file.file_seek(0)
          @sincedb[sincedb_key] = 0
        else
          # seek to end
          @logger.debug? && @logger.debug("#{path}: initial create, no sincedb, seeking to end #{stat.size}")
          watched_file.file_seek(stat.size)
          @sincedb[sincedb_key] = stat.size
        end
      elsif event == :create
        @sincedb[sincedb_key] = 0
      elsif event == :modify && @sincedb[sincedb_key].nil?
        @sincedb[sincedb_key] = 0
      elsif event == :unignore
        @sincedb[sincedb_key] = watched_file.bytes_read
      else
        @logger.debug? && @logger.debug("#{path}: staying at position 0, no sincedb")
      end
      return true
    end # def _add_to_sincedb

    public
    def sincedb_write(reason=nil)
      @logger.debug? && @logger.debug("caller requested sincedb write (#{reason})")
      _sincedb_write
    end

    private
    def _sincedb_open
      path = @opts[:sincedb_path]
      begin
        File.open(path) do |db|
          @logger.debug? && @logger.debug("_sincedb_open: reading from #{path}")
          db.each do |line|
            ino, dev_major, dev_minor, pos = line.split(" ", 4)
            sincedb_key = [ino, dev_major.to_i, dev_minor.to_i]
            @logger.debug? && @logger.debug("_sincedb_open: setting #{sincedb_key.inspect} to #{pos.to_i}")
            @sincedb[sincedb_key] = pos.to_i
          end
        end
      rescue
        #No existing sincedb to load
        @logger.debug? && @logger.debug("_sincedb_open: error: #{path}: #{$!}")
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
        @logger.debug? && @logger.debug("_sincedb_write: error: #{path}: #{$!}")
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
  end # module TailBase
end # module FileWatch
